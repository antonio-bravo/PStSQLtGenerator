function New-PSTGFKTest {
    <#
    .SYNOPSIS
        Function to test Foreing Keys

    .DESCRIPTION
        The function will retrieve the FK and create a test for it

    .PARAMETER SqlInstance
        The target SQL Server instance or instances. Server version must be SQL Server version 2012 or higher.

    .PARAMETER SqlCredential
        Login to the target instance using alternative credentials. Accepts PowerShell credentials (Get-Credential).

        Windows Authentication, SQL Server Authentication, Active Directory - Password, and Active Directory - Integrated are all supported.

        For MFA support, please use Connect-DbaInstance.

    .PARAMETER Database
        The database or databases to add.

    .PARAMETER Schema
        Filter the tables based on schema

    .PARAMETER Table
        Table(s) to create tests for

    .PARAMETER OutputPath
        Path to output the test to

    .PARAMETER Creator
        The person that created the tests. By default the command will get the environment username

    .PARAMETER TemplateFolder
        Path to template folder. By default the internal templates folder will be used

    .PARAMETER TestClass
        Test class name to use for the test

    .PARAMETER InputObject
        Takes the parameters required from a Table object that has been piped into the command

    .PARAMETER WhatIf
        Shows what would happen if the command were to run. No actions are actually performed.

    .PARAMETER Confirm
        Prompts you for confirmation before executing any changing operations within the command.

    .PARAMETER EnableException
        By default, when something goes wrong we try to catch it, interpret it and give you a friendly warning message.
        This avoids overwhelming you with "sea of red" exceptions, but is inconvenient because it basically disables advanced scripting.
        Using this switch turns this "nice by default" feature off and enables you to catch exceptions with your own try/catch.

    .EXAMPLE
        New-PSTGFKTest -Table $table -OutputPath $OutputPath

        Create a FK  test

    .EXAMPLE
        $tables | New-PSTGFKTest -OutputPath $OutputPath

        Create the tests using pipelines
    #>

    [CmdletBinding(SupportsShouldProcess)]

    param(
        [DbaInstanceParameter]$SqlInstance,
        [pscredential]$SqlCredential,
        [string]$Database,
        [string[]]$Schema,
        [string[]]$Table,
        [string]$OutputPath,
        [string]$Creator,
        [string]$TemplateFolder,
        [string]$TestClass,
        [parameter(ParameterSetName = "InputObject", ValueFromPipeline)]
        [Microsoft.SqlServer.Management.Smo.IndexedColumn[]]$InputObject,
        [switch]$EnableException
    )

    begin {
        # Check parameters
        if (-not $SqlInstance) {
            Stop-PSFFunction -Message "Please enter a SQL Server instance" -Target $SqlInstance
            return
        }

        if (-not $Database) {
            Stop-PSFFunction -Message "Please enter a database" -Target $Database
            return
        }

        # Check the output path
        if (-not $OutputPath) {
            Stop-PSFFunction -Message "Please enter an output path"
            return
        }

        if (-not (Test-Path -Path $OutputPath)) {
            try {
                $null = New-Item -Path $OutputPath -ItemType Directory
            }
            catch {
                Stop-PSFFunction -Message "Something went wrong creating the output directory" -Target $OutputPath -ErrorRecord $_
            }
        }

        # Check the template folder
        if (-not $TemplateFolder) {
            $TemplateFolder = Join-Path -Path ($script:ModuleRoot) -ChildPath "internal\templates"
        }

        if (-not (Test-Path -Path $TemplateFolder)) {
            Stop-PSFFunction -Message "Could not find template folder" -Target $OutputPath
        }

        if (-not $TestClass) {
            $TestClass = "TestBasic"
        }

        $date = Get-Date -Format (Get-culture).DateTimeFormat.ShortDatePattern

        if (-not $Creator) {
            $Creator = $env:username
        }

        # Connect to the server
        try {
            $server = Connect-DbaInstance -SqlInstance $Sqlinstance -SqlCredential $SqlCredential
        }
        catch {
            Stop-PSFFunction -Message "Could not connect to '$Sqlinstance'" -Target $Sqlinstance -ErrorRecord $_ -Category ConnectionError
            return
        }

        # Check if the database exists
        if ($Database -notin $server.Databases.Name) {
            Stop-PSFFunction -Message "Database '$Database' cannot be found on '$SqlInstance'" -Target $Database
        }

        $q = "select s.name from sys.schemas s join sys.extended_properties ep on ep.major_id = s.schema_id where ep.name like 'tSQLt.%' UNION ALL SELECT 'tSQLt'"
        $SkipDBTests = Invoke-DbaQuery -SqlInstance $Sqlinstance -SqlCredential $SqlCredential -Query $q -Database $Database

        $task = "Collecting objects"
        Write-Progress -ParentId 1 -Activity " FK" -Status 'Progress->' -CurrentOperation $task -Id 2

        $tables = @()

        if ($Schema) {
            $tables += $server.Databases[$Database].Tables | Where-Object { $_.IsSystemObject -eq $false -and $_.Schema -in $Schema }  | Where-Object Schema -NotIn $SkipDBTests.name | Select-Object Schema, Name, ForeignKeys
        }
        else {
            $tables += $server.Databases[$Database].Tables | Where-Object { $_.IsSystemObject -eq $false }  | Where-Object Schema -NotIn $SkipDBTests.name | Select-Object Schema, Name, ForeignKeys
        }

        if ($Table) {
            $tables = $tables | Where-Object Name -in $Table  | Where-Object Schema -NotIn $SkipDBTests.name
        }
    }

    process {
        if (Test-PSFFunctionInterrupt) { return }

        if (-not $InputObject -and -not $Table -and -not $SqlInstance) {
            Stop-PSFFunction -Message "You must pipe in an object or specify a Table"
            return
        }

        $objects = @()

        if ($InputObject) {
            $objects += $tables.ForeignKeys | Where-Object Name -in $InputObject  | Where-Object Schema -NotIn $SkipDBTests.name | Select-Object Name, ForeignKeys
        }
        else {
            $objects += $tables.ForeignKeys  | Where-Object Schema -NotIn $SkipDBTests.name | Select-Object Name, ForeignKeys
        }

        if ($Index) {
            $objects = $objects | Where-Object Name -in $Index  | Where-Object Schema -NotIn $SkipDBTests.name
        }

        $objectCount = $objects.Count
        $objectStep = 1

        if ($objectCount -ge 1) {
            foreach ($indexObject in $objects) {
                $task = "Creating FK column test $($objectStep) of $($objectCount)"
                Write-Progress -ParentId 1 -Activity "Creating..." -Status 'Progress->' -PercentComplete ($objectStep / $objectCount * 100) -CurrentOperation $task -Id 2

                $testName = "test If FK $($indexObject.Name) has the correct columns"

                # Test if the name of the test does not become too long
                if ($testName.Length -gt 128) {
                    Stop-PSFFunction -Message "Name of the test is too long" -Target $testName
                }

                $fileName = Join-Path -Path $OutputPath -ChildPath "$($testName).sql"
                $date = Get-Date -Format (Get-culture).DateTimeFormat.ShortDatePattern
                $creator = $env:username

                # Import the template
                try {
                    $script = Get-Content -Path (Join-Path -Path $TemplateFolder -ChildPath "FKColumnTest.template")
                }
                catch {
                    Stop-PSFFunction -Message "Could not import test template 'FKColumnTest.template'" -Target $testName -ErrorRecord $_
                }

                # Get the columns
                $query = "select 
                ss.name as SourceSchema
                ,so.name as SourceTable
                ,f.name as FKName
                ,sc.name as SourceColumn
                ,f.is_disabled
                ,f.is_not_for_replication
                ,f.is_published
                ,f.update_referential_action
                ,f.delete_referential_action
                ,rc.name as TargetColumn
                ,rs.name as TargetSchema
                ,ro.name as TargetTable
                from sys.foreign_keys f
                join sys.foreign_key_columns fc on fc.constraint_object_id = f.object_id
                                                AND fc.parent_object_id = f.parent_object_id
                join sys.columns sc on sc.object_id = f.parent_object_id
                                    AND sc.column_id = fc.parent_column_id
                join sys.objects so on so.object_id = f.parent_object_id
                join sys.schemas ss on ss.schema_id = so.schema_id
                
                join sys.foreign_key_columns fcr on fcr.constraint_object_id = f.object_id
                
                join sys.columns rc on rc.object_id = fc.referenced_object_id
                                      and rc.column_id = fc.referenced_column_id
                join sys.objects ro on ro.object_id = fc.referenced_object_id
                join sys.schemas rs on rs.schema_id = ro.schema_id
                
                where f.is_ms_shipped = 0
                --AND f.parent_object_id = OBJECT_ID('Sales.Store')
                AND f.name = '$($indexObject.Name)';"

                try {
                    $columns = Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $Database -Query $query
                }
                catch {
                    Stop-PSFFunction -Message "Could not retrieve columns for [$($indexObject.Schema)].[$($indexObject.Name)]" -Target $indexObject -Continue
                }

                $columnTextCollection = @()

                # Loop through the columns
                foreach ($column in $columns) {
                    $columnText = "`t('$($column.SourceSchema)', '$($column.SourceTable)', '$($column.FKName)', '$($column.SourceColumn)', $($column.is_disabled), $($column.is_not_for_replication), $($column.is_published), $($column.update_referential_action), $($column.delete_referential_action), '$($column.TargetColumn)', '$($column.TargetSchema)', '$($column.TargetTable)')"
                    $columnTextCollection += $columnText
                }

                # Replace the markers with the content
                $script = $script.Replace("___TESTCLASS___", $TestClass)
                $script = $script.Replace("___TESTNAME___", $testName)
                $script = $script.Replace("___NAME___", $indexObject.Name)
                $script = $script.Replace("___CREATOR___", $creator)
                $script = $script.Replace("___DATE___", $date)
                $script = $script.Replace("___COLUMNS___", ($columnTextCollection -join ",`n") + ";")

                # Write the test
                if ($PSCmdlet.ShouldProcess("$($indexObject.Schema).$($indexObject.Name)", "Writing FK Column Test")) {
                    try {
                        Write-PSFMessage -Message "Creating FK column test for FK '$($indexObject.Name)'"
                        $script | Out-File -FilePath $fileName

                        [PSCustomObject]@{
                            TestName = $testName
                            Category = "FKColumn"
                            Creator  = $creator
                            FileName = $fileName
                        }
                    }
                    catch {
                        Stop-PSFFunction -Message "Something went wrong writing the test" -Target $testName -ErrorRecord $_
                    }
                }

                $objectStep++
            }
        }
    }
}