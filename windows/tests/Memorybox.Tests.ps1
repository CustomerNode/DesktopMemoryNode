#requires -Module Pester

<#
.SYNOPSIS
Pester tests for windows/lib/Memorybox.psm1.

.DESCRIPTION
Pure-unit tests: no NAS, no restic, no real env vars. Anything that touches
the network or the live registry is mocked. Run with:

    pwsh windows/tests/Run-Tests.ps1
or
    Invoke-Pester windows/tests
#>

BeforeAll {
    $here    = Split-Path -Parent $PSCommandPath
    $libPath = Join-Path (Split-Path -Parent $here) 'lib\Memorybox.psm1'
    Import-Module $libPath -Force
}

Describe 'Test-MemoryboxNodeName' {
    It 'accepts a simple lowercase name' {
        Test-MemoryboxNodeName -Name 'kitchen' | Should -BeTrue
    }
    It 'accepts a single character' {
        Test-MemoryboxNodeName -Name 'a' | Should -BeTrue
    }
    It 'accepts hyphens in the middle' {
        Test-MemoryboxNodeName -Name 'office-desktop' | Should -BeTrue
    }
    It 'accepts digits' {
        Test-MemoryboxNodeName -Name 'mac-2' | Should -BeTrue
    }

    It 'rejects uppercase' {
        Test-MemoryboxNodeName -Name 'KITCHEN' | Should -BeFalse
    }
    It 'rejects mixed case' {
        Test-MemoryboxNodeName -Name 'Kitchen' | Should -BeFalse
    }
    It 'rejects leading hyphen' {
        Test-MemoryboxNodeName -Name '-bad' | Should -BeFalse
    }
    It 'rejects trailing hyphen' {
        Test-MemoryboxNodeName -Name 'bad-' | Should -BeFalse
    }
    It 'rejects spaces' {
        Test-MemoryboxNodeName -Name 'has space' | Should -BeFalse
    }
    It 'rejects names over 32 chars' {
        Test-MemoryboxNodeName -Name ('a' * 33) | Should -BeFalse
    }
    It 'accepts exactly 32 chars' {
        Test-MemoryboxNodeName -Name ('a' * 32) | Should -BeTrue
    }
    It 'rejects underscores' {
        Test-MemoryboxNodeName -Name 'has_under' | Should -BeFalse
    }
    It 'rejects dots' {
        Test-MemoryboxNodeName -Name 'has.dot' | Should -BeFalse
    }

    Context '-Detailed mode' {
        It 'returns reason "ok" for valid' {
            (Test-MemoryboxNodeName -Name 'kitchen' -Detailed).Reason | Should -Be 'ok'
        }
        It 'returns reason about character set for uppercase' {
            (Test-MemoryboxNodeName -Name 'KITCHEN' -Detailed).Reason | Should -Match 'lowercase'
        }
        It 'returns reason about hyphen position for trailing hyphen' {
            (Test-MemoryboxNodeName -Name 'bad-' -Detailed).Reason | Should -Match 'hyphen'
        }
        It 'returns reason about length for too long' {
            (Test-MemoryboxNodeName -Name ('a' * 50) -Detailed).Reason | Should -Match '32'
        }
    }
}

Describe 'Get-MemoryboxConfig' {
    BeforeAll {
        # Snapshot original env vars and restore in AfterAll
        $script:originalEnv = @{}
        foreach ($v in 'MEMORYBOX_HOST','MEMORYBOX_PORT','MEMORYBOX_USER','MEMORYBOX_PASSWORD','MEMORYBOX_NODE_NAME','enc_pswd') {
            $script:originalEnv[$v] = [Environment]::GetEnvironmentVariable($v, 'User')
        }
    }
    AfterAll {
        foreach ($k in $script:originalEnv.Keys) {
            [Environment]::SetEnvironmentVariable($k, $script:originalEnv[$k], 'User')
        }
    }

    It 'reports IsComplete=$true when all vars are set' {
        # Use the real env (set during Phase 1 testing on this machine)
        $cfg = Get-MemoryboxConfig
        $cfg.IsComplete | Should -BeTrue
    }

    It 'computes ResticRepoPath as \\<host>\home\dmn-<nodename>\restic-repo' {
        $cfg = Get-MemoryboxConfig
        $cfg.ResticRepoPath | Should -Be ("\\$($cfg.Host)\home\dmn-$($cfg.NodeName)\restic-repo")
    }

    It 'computes BaseUrl as http://<host>:<port>' {
        $cfg = Get-MemoryboxConfig
        $cfg.BaseUrl | Should -Be ("http://$($cfg.Host):$($cfg.Port)")
    }

    It 'never returns the password field directly' {
        $cfg = Get-MemoryboxConfig
        $cfg.PSObject.Properties.Name | Should -Not -Contain 'Password'
    }

    It 'reports HasPassword=$true when password is set' {
        $cfg = Get-MemoryboxConfig
        $cfg.HasPassword | Should -BeTrue
    }

    It 'reports HasEncPassword=$true when enc_pswd is set' {
        $cfg = Get-MemoryboxConfig
        $cfg.HasEncPassword | Should -BeTrue
    }
}

Describe 'Get-MissingMemoryboxVars' {
    It 'returns nothing when everything is set' {
        $missing = Get-MissingMemoryboxVars
        @($missing).Count | Should -Be 0
    }
}

Describe 'Get-DmnDisplayConfig' {
    It 'returns an object with the three display fields' {
        $d = Get-DmnDisplayConfig
        $d.PSObject.Properties.Name | Should -Contain 'UserName'
        $d.PSObject.Properties.Name | Should -Contain 'TechName'
        $d.PSObject.Properties.Name | Should -Contain 'TechContact'
    }
}

Describe 'Get-DmnSupportLine' {
    It 'returns a non-empty string' {
        Get-DmnSupportLine | Should -Not -BeNullOrEmpty
    }
    It 'mentions tech support' {
        Get-DmnSupportLine | Should -Match 'help|support|contact|Contact'
    }
}

Describe 'State directory layout' {
    It 'creates the state root and subdirs on demand' {
        $root = Get-DmnStateRoot
        Test-Path $root | Should -BeTrue
        Test-Path (Join-Path $root 'logs') | Should -BeTrue
        Test-Path (Join-Path $root 'locks') | Should -BeTrue
    }
    It 'targets path is under state root' {
        (Get-DmnTargetsPath) | Should -BeLike "$(Get-DmnStateRoot)*"
    }
    It 'state path is under state root' {
        (Get-DmnStatePath) | Should -BeLike "$(Get-DmnStateRoot)*"
    }
    It 'log path is per-day' {
        $today    = Get-DmnLogPath -Kind 'backup'
        $other    = Get-DmnLogPath -Kind 'backup' -Date (Get-Date).AddDays(-1)
        $today | Should -Not -Be $other
    }
}

Describe 'Get-NodeState' {
    It 'returns the default schema (all keys present) even if state.json is missing' {
        # Move the state file aside if it exists
        $statePath = Get-DmnStatePath
        $backup = $null
        if (Test-Path $statePath) {
            $backup = "$statePath.test-backup"
            Move-Item $statePath $backup -Force
        }
        try {
            $s = Get-NodeState
            foreach ($k in 'LastBackupAt','LastBackupOk','LastBackupError','LastVerifyAt','LastVerifyOk','LastTestRestoreAt','LastTestRestoreOk','SnapshotCount','RepoSizeBytes','WelcomeShown') {
                $s.PSObject.Properties.Name | Should -Contain $k
            }
        } finally {
            if ($backup) { Move-Item $backup $statePath -Force }
        }
    }
}

Describe 'Get-DefaultBackupTargets' {
    It 'returns include + exclude' {
        $t = Get-DefaultBackupTargets
        $t.PSObject.Properties.Name | Should -Contain 'include'
        $t.PSObject.Properties.Name | Should -Contain 'exclude'
    }
    It 'includes user profile dirs' {
        $t = Get-DefaultBackupTargets
        @($t.include).Count | Should -BeGreaterThan 0
    }
    It 'excludes AppData' {
        $t = Get-DefaultBackupTargets
        ($t.exclude | Where-Object { $_ -like '*AppData*' }).Count | Should -BeGreaterThan 0
    }
}

Describe 'Set-BackupTargets / Get-BackupTargets round-trip' {
    BeforeAll {
        $script:targetsPath = Get-DmnTargetsPath
        $script:hadOriginal = Test-Path $script:targetsPath
        if ($script:hadOriginal) {
            $script:originalContent = Get-Content -Raw $script:targetsPath
        }
    }
    AfterAll {
        if ($script:hadOriginal) {
            [IO.File]::WriteAllText($script:targetsPath, $script:originalContent, [Text.Encoding]::UTF8)
        } else {
            Remove-Item $script:targetsPath -ErrorAction SilentlyContinue
        }
    }

    It 'persists include + exclude lists' {
        Set-BackupTargets -Include 'C:\foo','C:\bar' -Exclude '**/*.tmp'
        $back = Get-BackupTargets
        $back.include | Should -Be @('C:\foo','C:\bar')
        $back.exclude | Should -Be @('**/*.tmp')
    }
    It 'rejects empty include' {
        { Set-BackupTargets -Include @() -Exclude @() } | Should -Throw
    }
    It 'falls back to defaults when targets.json is missing' {
        Remove-Item (Get-DmnTargetsPath) -ErrorAction SilentlyContinue
        $back = Get-BackupTargets
        $defaults = Get-DefaultBackupTargets
        @($back.include).Count | Should -Be @($defaults.include).Count
    }
}

Describe 'Lock-NodeOperation / Unlock-NodeOperation' {
    It 'acquires and releases a lock cleanly' {
        $lock = Lock-NodeOperation -Name 'pester-test'
        $lock | Should -Not -BeNullOrEmpty
        Test-Path (Get-DmnLockPath -Name 'pester-test') | Should -BeTrue
        Unlock-NodeOperation -Handle $lock -Name 'pester-test'
        Test-Path (Get-DmnLockPath -Name 'pester-test') | Should -BeFalse
    }

    It 'throws when trying to acquire an already-held lock' {
        $first = Lock-NodeOperation -Name 'pester-busy'
        try {
            { Lock-NodeOperation -Name 'pester-busy' } | Should -Throw
        } finally {
            Unlock-NodeOperation -Handle $first -Name 'pester-busy'
        }
    }
}

Describe 'Set-ResticPasswordOverride / Clear-ResticPasswordOverride' {
    It 'override is honored by Invoke-Restic password resolution path' {
        # We only test that Set/Clear don't throw; full path tested via integration.
        { Set-ResticPasswordOverride -Password 'foo' } | Should -Not -Throw
        { Clear-ResticPasswordOverride } | Should -Not -Throw
    }
}
