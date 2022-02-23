$script:ModuleRoot = $PSScriptRoot
$script:ModuleVersion = (Import-PowerShellDataFile -Path "$($script:ModuleRoot)\PStSQLtTestGenerator.psd1").ModuleVersion

# Detect whether at some level dotsourcing was enforced
$script:doDotSource = Get-PSFConfigValue -FullName PStSQLtTestGenerator.Import.DoDotSource -Fallback $false
if ($PStSQLtTestGenerator_dotsourcemodule) { $script:doDotSource = $true }

<#
Note on Resolve-Path:
All paths are sent through Resolve-Path/Resolve-PSFPath in order to convert them to the correct path separator.
This allows ignoring path separators throughout the import sequence, which could otherwise cause trouble depending on OS.
Resolve-Path can only be used for paths that already exist, Resolve-PSFPath can accept that the last leaf my not exist.
This is important when testing for paths.
#>

# Detect whether at some level loading individual module files, rather than the compiled module was enforced
$importIndividualFiles = Get-PSFConfigValue -FullName PStSQLtTestGenerator.Import.IndividualFiles -Fallback $false
if ($PStSQLtTestGenerator_importIndividualFiles) { $importIndividualFiles = $true }
if (Test-Path (Resolve-PSFPath -Path "$($script:ModuleRoot)\..\.git" -SingleItem -NewChild)) { $importIndividualFiles = $true }
if ("<was compiled>" -eq '<was not compiled>') { $importIndividualFiles = $true }
	
function Import-ModuleFile
{
	<#
		.SYNOPSIS
			Loads files into the module on module import.
		
		.DESCRIPTION
			This helper function is used during module initialization.
			It should always be dotsourced itself, in order to proper function.
			
			This provides a central location to react to files being imported, if later desired
		
		.PARAMETER Path
			The path to the file to load
		
		.EXAMPLE
			PS C:\> . Import-ModuleFile -File $function.FullName
	
			Imports the file stored in $function according to import policy
	#>
	[CmdletBinding()]
	Param (
		[string]
		$Path
	)
	
	$resolvedPath = $ExecutionContext.SessionState.Path.GetResolvedPSPathFromPSPath($Path).ProviderPath
	if ($doDotSource) { . $resolvedPath }
	else { $ExecutionContext.InvokeCommand.InvokeScript($false, ([scriptblock]::Create([io.file]::ReadAllText($resolvedPath))), $null, $null) }
}

#region Load individual files
if ($importIndividualFiles)
{
	# Execute Preimport actions
	. Import-ModuleFile -Path "$ModuleRoot\internal\scripts\preimport.ps1"
	
	# Import all internal functions
	foreach ($function in (Get-ChildItem "$ModuleRoot\internal\functions" -Filter "*.ps1" -Recurse -ErrorAction Ignore))
	{
		. Import-ModuleFile -Path $function.FullName
	}
	
	# Import all public functions
	foreach ($function in (Get-ChildItem "$ModuleRoot\functions" -Filter "*.ps1" -Recurse -ErrorAction Ignore))
	{
		. Import-ModuleFile -Path $function.FullName
	}
	
	# Execute Postimport actions
	. Import-ModuleFile -Path "$ModuleRoot\internal\scripts\postimport.ps1"
	
	# End it here, do not load compiled code below
	return
}
#endregion Load individual files

#region Load compiled code
function Invoke-PSTGTestGenerator {
    <#
    .SYNOPSIS
        Create the basic tests for the database project

    .DESCRIPTION
        The script will connect to a database on a SQL Server instance, iterate through objects and create tests for the objects.

        The script will create the following tests
        - Test if the database settings (i.e. collation) are correct
        - Test if an object (Function, Procedure, Table, View etc) exists
        - Test if an object (Function or Procedure) has the correct parameters
        - Test if an object (Table or View) has the correct columns

        Each object and each test will be it's own file.

   .PARAMETER SqlInstance
        The target SQL Server instance or instances. Server version must be SQL Server version 2012 or higher.

        This should be the primary replica.

    .PARAMETER SqlCredential
        Login to the target instance using alternative credentials. Accepts PowerShell credentials (Get-Credential).

        Windows Authentication, SQL Server Authentication, Active Directory - Password, and Active Directory - Integrated are all supported.

        For MFA support, please use Connect-DbaInstance.

    .PARAMETER Database
        The database or databases to add.

    .PARAMETER OutputPath
        Folder where the files should be written to

    .PARAMETER Creator
        The person that created the tests. By default the command will get the environment username

    .PARAMETER TemplateFolder
        The template folder containing all the templates for the tests.
        By default it will use the internal templates directory

    .PARAMETER Schema
        Filter the functions based on schema

    .PARAMETER Function
        Filter out specific functions that should only be processed

    .PARAMETER Procedure
        Filter out specific procedures that should only be processed

    .PARAMETER Table
        Filter out specific tables that should only be processed

    .PARAMETER Index
        Filter out specific indexes that should be processed

    .PARAMETER View
        Filter out specific views that should only be processed

    .PARAMETER SkipDatabaseTests
        Skip the database tests

    .PARAMETER SkipFunctionTests
        Skip the function tests

    .PARAMETER SkipProcedureTests
        Skip the procedure tests

    .PARAMETER SkipTableTests
        Skip the table tests

    .PARAMETER SkipViewTests
        Skip the view tests

    .PARAMETER SkipIndexTests
        Skip the view tests

    .PARAMETER TestClass
        Test class name to use for the test

    .PARAMETER WhatIf
        Shows what would happen if the command were to run. No actions are actually performed.

    .PARAMETER Confirm
        Prompts you for confirmation before executing any changing operations within the command.

    .PARAMETER EnableException
        By default, when something goes wrong we try to catch it, interpret it and give you a friendly warning message.
        This avoids overwhelming you with "sea of red" exceptions, but is inconvenient because it basically disables advanced scripting.
        Using this switch turns this "nice by default" feature off and enables you to catch exceptions with your own try/catch.

    .EXAMPLE
        PS C:\> Invoke-PSTGTestGenerator -SqlInstance SQLDB1 -Database DB1 -OutputPath c:\projects\DB1\DB1-Tests\TestBasic

        Iterate through all the objects and output the files to "c:\projects\DB1\DB1-Tests\TestBasic"

    .EXAMPLE
        PS C:\> Invoke-PSTGTestGenerator -SqlInstance SQLDB1 -Database DB1 -OutputPath c:\projects\DB1\DB1-Tests\TestBasic -Procedure Proc1, Proc2

        Iterate through all the objects but only do "Proc1" and "Proc2" for the procedures.

        NOTE! All other tests like the table, function and view tests will still be generated

    .EXAMPLE
        PS C:\> Invoke-PSTGTestGenerator -SqlInstance SQLDB1 -Database DB1 -OutputPath c:\projects\DB1\DB1-Tests\TestBasic -SkipProcedureTests

        Iterate through all the objects but do not process the procedures
    #>

    [CmdletBinding()]

    param(
        [DbaInstanceParameter]$SqlInstance,
        [pscredential]$SqlCredential,
        [string]$Database,
        [string]$OutputPath,
        [string]$Creator,
        [string]$TemplateFolder,
        [string[]]$Schema,
        [string[]]$Function,
        [string[]]$Procedure,
        [string[]]$Table,
        [string[]]$Index,
        [string[]]$View,
        [switch]$SkipDatabaseTests,
        [switch]$SkipFunctionTests,
        [switch]$SkipProcedureTests,
        [switch]$SkipTableTests,
        [switch]$SkipIndexTests,
        [switch]$SkipViewTests,
        [string]$TestClass,
        [switch]$EnableException
    )

    begin {
        # Check the parameters
        if (-not $SqlInstance) {
            Stop-PSFFunction -Message "Please enter a SQL Server instance" -Target $SqlInstance
            return
        }

        if (-not $Database) {
            Stop-PSFFunction -Message "Please enter a database" -Target $Database
            return
        }

        if (-not $OutputPath) {
            Stop-PSFFunction -Message "Please enter path to output the files to" -Target $OutputPath
            return
        }

        if (-not (Test-Path -Path $OutputPath)) {
            Stop-PSFFunction -Message "Could not access output path" -Category ResourceUnavailable -Target $OutputPath
            return
        }

        if (-not $Creator) {
            $Creator = $env:username
        }

        if (-not $TemplateFolder) {
            $TemplateFolder = Join-Path -Path ($script:ModuleRoot) -ChildPath "internal\templates"
        }

        if (-not (Test-Path -Path $TemplateFolder)) {
            Stop-PSFFunction -Message "Could not find template folder" -Target $OutputPath
            return
        }

        if (-not $TestClass) {
            $TestClass = "TestBasic"
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
            Stop-PSFFunction -Message "Database cannot be found on '$SqlInstance'" -Target $Database
        }

        $q = "select s.name from sys.schemas s join sys.extended_properties ep on ep.major_id = s.schema_id where ep.name like 'tSQLt.%' UNION ALL SELECT 'tSQLt'"
        $SkipDBTests = Invoke-DbaQuery -SqlInstance $Sqlinstance -SqlCredential $SqlCredential -Query $q -Database $Database
    }

    process {
        if (Test-PSFFunctionInterrupt) { return }

        $db = $server.Databases[$Database]

        #########################################################################
        # Create the database tests
        #########################################################################

        $totalSteps = 7
        $currentStep = 1
        $task = "Creating Unit Tests"

        $progressParams = @{
            Id               = 1
            Activity         = "Creating tSQLt Unit Tests"
            Status           = 'Progress->'
            PercentComplete  = $null
            CurrentOperation = $task
        }

        if (-not $SkipDatabaseTests) {
            $progressParams.PercentComplete = $($currentStep / $totalSteps * 100)
            Write-Progress @progressParams

            try {
                # Create the collation test
                New-PSTGDatabaseCollationTest -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $Database -Creator $Creator -TemplateFolder $TemplateFolder -OutputPath $OutputPath -TestClass $TestClass -EnableException
            }
            catch {
                Stop-PSFFunction -Message "Something went wrong creating the database collation test" -Target $Database -ErrorRecord $_
            }

        }

        #########################################################################
        # Create the function tests
        #########################################################################

        $currentStep = 2

        if (-not $SkipFunctionTests) {
            $progressParams.PercentComplete = $($currentStep / $totalSteps * 100)
            Write-Progress @progressParams

            $dbObjects = @()

            if ($Schema) {
                $dbObjects += $db.UserDefinedFunctions | Where-Object IsSystemObject -eq $false | Where-Object Schema -in $Schema | Where-Object Schema -NotIn $SkipDBTests.name
            }
            else {
                $dbObjects += $db.UserDefinedFunctions | Where-Object IsSystemObject -eq $false | Where-Object Schema -NotIn $SkipDBTests.name
            }

            if ($Function) {
                $dbObjects = $dbObjects | Where-Object Name -in $Function | Where-Object Schema -NotIn $SkipDBTests.name
            }

            # Create the function existence tests
            try {
                $params = @{
                    SqlInstance     = $SqlInstance
                    SqlCredential   = $SqlCredential
                    Database        = $Database
                    Schema          = @($dbObjects | Select-Object Schema -ExpandProperty Schema -Unique)
                    Object          = @($dbObjects | Select-Object Name -ExpandProperty Name -Unique)
                    Creator         = $Creator
                    OutputPath      = $OutputPath
                    TestClass       = $TestClass
                    EnableException = $EnableException
                }

                New-PSTGObjectExistenceTest @params
            }
            catch {
                Stop-PSFFunction -Message "Something went wrong creating the function existence tests" -Target $Database -ErrorRecord $_
            }

            # Create the function parameter tests
            try {
                $params = @{
                    SqlInstance     = $SqlInstance
                    SqlCredential   = $SqlCredential
                    Database        = $Database
                    Schema          = @($dbObjects | Select-Object Schema -ExpandProperty Schema -Unique)
                    Function        = @($dbObjects | Select-Object Name -ExpandProperty Name -Unique)
                    Creator         = $Creator
                    OutputPath      = $OutputPath
                    TestClass       = $TestClass
                    EnableException = $EnableException
                }

                New-PSTGFunctionParameterTest @params
            }
            catch {
                Stop-PSFFunction -Message "Something went wrong creating the function parameter tests" -Target $Database -ErrorRecord $_
            }
        }

        #########################################################################
        # Create the procedure tests
        #########################################################################

        $currentStep = 3

        if (-not $SkipProcedureTests) {
            $progressParams.PercentComplete = $($currentStep / $totalSteps * 100)
            Write-Progress @progressParams

            $dbObjects = @()

            $dbObjects += Get-DbaModule -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $Database -Type StoredProcedure -ExcludeSystemObjects | Where-Object SchemaName -NotIn $SkipDBTests.name | Select-Object SchemaName, Name

            if ($Schema) {
                $dbObjects = $dbObjects | Where-Object SchemaName -in $Schema | Where-Object SchemaName -NotIn $SkipDBTests.name
            }

            if ($Procedure) {
                $dbObjects = $dbObjects | Where-Object Name -in $Procedure | Where-Object SchemaName -NotIn $SkipDBTests.name
            }

            # Create the procedure existence tests
            try {
                $params = @{
                    SqlInstance     = $SqlInstance
                    SqlCredential   = $SqlCredential
                    Database        = $Database
                    Schema          = @($dbObjects | Select-Object SchemaName -ExpandProperty SchemaName -Unique)
                    Object          = @($dbObjects | Select-Object Name -ExpandProperty Name -Unique)
                    Creator         = $Creator
                    OutputPath      = $OutputPath
                    TestClass       = $TestClass
                    EnableException = $EnableException
                }

                New-PSTGObjectExistenceTest @params
            }
            catch {
                Stop-PSFFunction -Message "Something went wrong creating the procedure existence tests" -Target $Database -ErrorRecord $_
            }

            # Create the procedure parameter tests
            try {
                $params = @{
                    SqlInstance     = $SqlInstance
                    SqlCredential   = $SqlCredential
                    Database        = $Database
                    Schema          = @($dbObjects | Select-Object SchemaName -ExpandProperty SchemaName -Unique)
                    Procedure       = @($dbObjects | Select-Object Name -ExpandProperty Name -Unique)
                    Creator         = $Creator
                    OutputPath      = $OutputPath
                    TestClass       = $TestClass
                    EnableException = $EnableException
                }

                New-PSTGProcedureParameterTest @params
            }
            catch {
                Stop-PSFFunction -Message "Something went wrong creating the procedure parameter tests" -Target $Database -ErrorRecord $_
            }
        }

        #########################################################################
        # Create the table tests
        #########################################################################

        $currentStep = 4

        if (-not $SkipTableTests) {
            $progressParams.PercentComplete = $($currentStep / $totalSteps * 100)
            Write-Progress @progressParams

            $dbObjects = @()

            if ($Schema) {
                $dbObjects += $db.Tables | Where-Object IsSystemObject -eq $false | Where-Object Schema -in $Schema | Where-Object Schema -NotIn $SkipDBTests.name
            }
            else {
                $dbObjects += $db.Tables | Where-Object IsSystemObject -eq $false | Where-Object Schema -NotIn $SkipDBTests.name
            }

            if ($Table) {
                $dbObjects = $dbObjects | Where-Object Name -in $Table | Where-Object Schema -NotIn $SkipDBTests.name
            }

            # Create the table existence tests
            try {
                $params = @{
                    SqlInstance     = $SqlInstance
                    SqlCredential   = $SqlCredential
                    Database        = $Database
                    Schema          = @($dbObjects | Select-Object Schema -ExpandProperty Schema -Unique)
                    Object          = @($dbObjects | Select-Object Name -ExpandProperty Name -Unique)
                    Creator         = $Creator
                    OutputPath      = $OutputPath
                    TestClass       = $TestClass
                    EnableException = $EnableException
                }

                New-PSTGObjectExistenceTest @params
            }
            catch {
                Stop-PSFFunction -Message "Something went wrong creating the table existence tests" -Target $Database -ErrorRecord $_
            }

            # Create the table column tests
            try {
                $params = @{
                    SqlInstance     = $SqlInstance
                    SqlCredential   = $SqlCredential
                    Database        = $Database
                    Schema          = @($dbObjects | Select-Object Schema -ExpandProperty Schema -Unique)
                    Table           = @($dbObjects | Select-Object Name -ExpandProperty Name -Unique)
                    Creator         = $Creator
                    OutputPath      = $OutputPath
                    TestClass       = $TestClass
                    EnableException = $EnableException
                }

                New-PSTGTableColumnTest @params
            }
            catch {
                Stop-PSFFunction -Message "Something went wrong creating the table column tests" -Target $Database -ErrorRecord $_
            }
        }

        #########################################################################
        # Create the table index tests
        #########################################################################

        $currentStep = 5

        if (-not $SkipIndexTests) {
            $progressParams.PercentComplete = $($currentStep / $totalSteps * 100)
            Write-Progress @progressParams

            $dbObjects = @()

            if ($Schema) {
                $dbObjects += $db.Tables | Where-Object IsSystemObject -eq $false | Where-Object Schema -in $Schema | Where-Object Schema -NotIn $SkipDBTests.name
            }
            else {
                $dbObjects += $db.Tables | Where-Object IsSystemObject -eq $false | Where-Object Schema -NotIn $SkipDBTests.name
            }

            if ($Table) {
                $dbObjects = $dbObjects | Where-Object Name -in $Table | Where-Object Schema -NotIn $SkipDBTests.name
            }

            # Create the table index tests
            try {
                $params = @{
                    SqlInstance     = $SqlInstance
                    SqlCredential   = $SqlCredential
                    Database        = $Database
                    Schema          = @($dbObjects | Select-Object Schema -ExpandProperty Schema -Unique)
                    Table           = @($dbObjects | Select-Object Name -ExpandProperty Name -Unique)
                    Creator         = $Creator
                    OutputPath      = $OutputPath
                    TestClass       = $TestClass
                    EnableException = $EnableException
                }

                New-PSTGTableIndexTest @params
            }
            catch {
                Stop-PSFFunction -Message "Something went wrong creating the table index tests" -Target $Database -ErrorRecord $_
            }
        }

        #########################################################################
        # Create the index tests
        #########################################################################

        $currentStep = 6

        if (-not $SkipIndexTests) {
            $progressParams.PercentComplete = $($currentStep / $totalSteps * 100)
            Write-Progress @progressParams

            $dbObjects = @()

            if ($Schema) {
                $dbObjects += $db.Tables | Where-Object IsSystemObject -eq $false | Where-Object Schema -in $Schema | Where-Object Schema -NotIn $SkipDBTests.name
            }
            else {
                $dbObjects += $db.Tables | Where-Object IsSystemObject -eq $false | Where-Object Schema -NotIn $SkipDBTests.name
            }

            if ($Table) {
                $dbObjects = $dbObjects | Where-Object Name -in $Table | Where-Object Schema -NotIn $SkipDBTests.name
            }

            $indObjects = @()

            if ($Index) {
                $indObjects += $dbObjects.Indexes | Where-Object Name -in $Index | Where-Object Schema -NotIn $SkipDBTests.name | Select-Object Name
            }
            else {
                $indObjects += $dbObjects.Indexes | Where-Object Schema -NotIn $SkipDBTests.name | Select-Object Name
            }

            # Create the index existence tests
            try {
                $params = @{
                    SqlInstance     = $SqlInstance
                    SqlCredential   = $SqlCredential
                    Database        = $Database
                    Schema          = @($dbObjects | Select-Object Schema -ExpandProperty Schema -Unique)
                    Table           = @($dbObjects | Select-Object Name -ExpandProperty Name -Unique)
                    Index           = @($indObjects | Select-Object Name -ExpandProperty Name -Unique)
                    Creator         = $Creator
                    OutputPath      = $OutputPath
                    TestClass       = $TestClass
                    EnableException = $EnableException
                }

                New-PSTGIndexColumnTest @params
            }
            catch {
                Stop-PSFFunction -Message "Something went wrong creating the index column tests" -Target $Database -ErrorRecord $_
            }
        }

        #########################################################################
        # Create the view tests
        #########################################################################

        $currentStep = 7

        if (-not $SkipViewTests) {
            $progressParams.PercentComplete = $($currentStep / $totalSteps * 100)
            Write-Progress @progressParams

            $dbObjects = @()

            if ($Schema) {
                $dbObjects += $db.Views | Where-Object IsSystemObject -eq $false | Where-Object Schema -in $Schema | Where-Object Schema -NotIn $SkipDBTests.name
            }
            else {
                $dbObjects += $db.Views | Where-Object IsSystemObject -eq $false | Where-Object Schema -NotIn $SkipDBTests.name
            }

            if ($View) {
                $dbObjects = $dbObjects | Where-Object Name -in $View | Where-Object Schema -NotIn $SkipDBTests.name
            }

            # Create the view existence tests
            try {
                $params = @{
                    SqlInstance     = $SqlInstance
                    SqlCredential   = $SqlCredential
                    Database        = $Database
                    Schema          = @($dbObjects | Select-Object Schema -ExpandProperty Schema -Unique)
                    Object          = @($dbObjects | Select-Object Name -ExpandProperty Name -Unique)
                    Creator         = $Creator
                    OutputPath      = $OutputPath
                    TestClass       = $TestClass
                    EnableException = $EnableException
                }

                New-PSTGObjectExistenceTest @params
            }
            catch {
                Stop-PSFFunction -Message "Something went wrong creating the view existence tests" -Target $Database -ErrorRecord $_
            }

            # Create the view column tests
            try {
                $params = @{
                    SqlInstance     = $SqlInstance
                    SqlCredential   = $SqlCredential
                    Database        = $Database
                    Schema          = @($dbObjects | Select-Object Schema -ExpandProperty Schema -Unique)
                    View            = @($dbObjects | Select-Object Name -ExpandProperty Name -Unique)
                    Creator         = $Creator
                    OutputPath      = $OutputPath
                    TestClass       = $TestClass
                    EnableException = $EnableException
                }

                New-PSTGViewColumnTest @params
            }
            catch {
                Stop-PSFFunction -Message "Something went wrong creating the view column tests" -Target $Database -ErrorRecord $_
            }
        }
    }
}

function New-PSTGDatabaseCollationTest {
    <#
    .SYNOPSIS
        Function to create a collation test

    .DESCRIPTION
        The function will lookup the current collation of the database and create a test with that value

    .PARAMETER SqlInstance
        The target SQL Server instance or instances. Server version must be SQL Server version 2012 or higher.

    .PARAMETER SqlCredential
        Login to the target instance using alternative credentials. Accepts PowerShell credentials (Get-Credential).

        Windows Authentication, SQL Server Authentication, Active Directory - Password, and Active Directory - Integrated are all supported.

        For MFA support, please use Connect-DbaInstance.

    .PARAMETER Database
        The database or databases to add.

    .PARAMETER OutputPath
        Path to output the test to

    .PARAMETER Creator
        The person that created the tests. By default the command will get the environment username

    .PARAMETER TemplateFolder
        Path to template folder. By default the internal templates folder will be used

    .PARAMETER TestClass
        Test class name to use for the test

    .PARAMETER WhatIf
        Shows what would happen if the command were to run. No actions are actually performed.

    .PARAMETER Confirm
        Prompts you for confirmation before executing any changing operations within the command.

    .PARAMETER EnableException
        By default, when something goes wrong we try to catch it, interpret it and give you a friendly warning message.
        This avoids overwhelming you with "sea of red" exceptions, but is inconvenient because it basically disables advanced scripting.
        Using this switch turns this "nice by default" feature off and enables you to catch exceptions with your own try/catch.

    .EXAMPLE
        New-PSTGDatabaseCollationTest -Database DB1 -OutputPath "C:\Projects\DB1\TestBasic\"

        Create a new database collation test
    #>

    [CmdletBinding(SupportsShouldProcess)]

    param(
        [DbaInstanceParameter]$SqlInstance,
        [pscredential]$SqlCredential,
        [string]$Database,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$Creator,
        [string]$TemplateFolder,
        [string]$TestClass,
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

        # Test if the name of the test does not become too long
        if ($testName.Length -gt 128) {
            Stop-PSFFunction -Message "Name of the test is too long" -Target $testName
        }

        if (-not $TestClass) {
            $TestClass = "TestBasic"
        }

        $date = Get-Date -Format (Get-culture).DateTimeFormat.ShortDatePattern

        if (-not $Creator) {
            $Creator = $env:username
        }

        if (-not $TemplateFolder) {
            $TemplateFolder = Join-Path -Path ($script:ModuleRoot) -ChildPath "internal\templates"
        }

        if (-not (Test-Path -Path $TemplateFolder)) {
            try {
                $null = New-Item -Path $OutputPath -ItemType Directory
            }
            catch {
                Stop-PSFFunction -Message "Something went wrong creating the output directory" -Target $OutputPath -ErrorRecord $_
            }
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
            Stop-PSFFunction -Message "Database cannot be found on '$SqlInstance'" -Target $Database
        }
    }

    process {
        if (Test-PSFFunctionInterrupt) { return }

        $testName = "test If database has correct collation"
        $fileName = Join-Path -Path $OutputPath -ChildPath "$($testName).sql"

        # Import the template
        try {
            $script = Get-Content -Path (Join-Path -Path $TemplateFolder -ChildPath "DatabaseCollationTest.template")
        }
        catch {
            Stop-PSFFunction -Message "Could not import test template 'DatabaseCollationTest.template'" -Target $testName -ErrorRecord $_
        }

        # Replace the markers with the content
        $script = $script.Replace("___TESTCLASS___", $TestClass)
        $script = $script.Replace("___TESTNAME___", $testName)
        $script = $script.Replace("___DATABASE___", $Database)
        $script = $script.Replace("___COLLATION___", $server.Databases[$Database].Collation)
        $script = $script.Replace("___CREATOR___", $creator)
        $script = $script.Replace("___DATE___", $date)

        # Write the test
        if ($PSCmdlet.ShouldProcess("$Database", "Writing Database Collation Test")) {
            try {
                Write-PSFMessage -Message "Creating collation test for '$Database'"
                $script | Out-File -FilePath $fileName

                [PSCustomObject]@{
                    TestName = $testName
                    Category = "DatabaseCollation"
                    Creator  = $creator
                    FileName = $fileName
                }
            }
            catch {
                Stop-PSFFunction -Message "Something went wrong writing the test" -Target $testName -ErrorRecord $_
            }
        }
    }
}

function New-PSTGFunctionParameterTest {
    <#
    .SYNOPSIS
        Function to create parameter tests

    .DESCRIPTION
        The function will retrieve the current parameters for a function and create a test for it

    .PARAMETER SqlInstance
        The target SQL Server instance or instances. Server version must be SQL Server version 2012 or higher.

    .PARAMETER SqlCredential
        Login to the target instance using alternative credentials. Accepts PowerShell credentials (Get-Credential).

        Windows Authentication, SQL Server Authentication, Active Directory - Password, and Active Directory - Integrated are all supported.

        For MFA support, please use Connect-DbaInstance.

    .PARAMETER Database
        The database or databases to add.

    .PARAMETER Schema
        Filter the functions based on schema

    .PARAMETER Function
        Function(s) to create tests for

    .PARAMETER OutputPath
        Path to output the test to

    .PARAMETER Creator
        The person that created the tests. By default the command will get the environment username

    .PARAMETER TemplateFolder
        Path to template folder. By default the internal templates folder will be used

    .PARAMETER TestClass
        Test class name to use for the test

    .PARAMETER InputObject
        Takes the parameters required from a Function object that has been piped into the command

    .PARAMETER WhatIf
        Shows what would happen if the command were to run. No actions are actually performed.

    .PARAMETER Confirm
        Prompts you for confirmation before executing any changing operations within the command.

    .PARAMETER EnableException
        By default, when something goes wrong we try to catch it, interpret it and give you a friendly warning message.
        This avoids overwhelming you with "sea of red" exceptions, but is inconvenient because it basically disables advanced scripting.
        Using this switch turns this "nice by default" feature off and enables you to catch exceptions with your own try/catch.

    .EXAMPLE
        New-PSTGFunctionParameterTest -Function $function -OutputPath $OutputPath

        Create a new function parameter test

    .EXAMPLE
        $functions | New-PSTGFunctionParameterTest -OutputPath $OutputPath

        Create the tests using pipelines
    #>

    [CmdletBinding(SupportsShouldProcess)]

    param(
        [DbaInstanceParameter]$SqlInstance,
        [pscredential]$SqlCredential,
        [string]$Database,
        [string[]]$Schema,
        [string[]]$Function,
        [string]$OutputPath,
        [string]$Creator,
        [string]$TemplateFolder,
        [string]$TestClass,
        [parameter(ParameterSetName = "InputObject", ValueFromPipeline)]
        [Microsoft.SqlServer.Management.Smo.UserDefinedFunction[]]$InputObject,
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
            Stop-PSFFunction -Message "Database cannot be found on '$SqlInstance'" -Target $Database
        }

        $q = "select s.name from sys.schemas s join sys.extended_properties ep on ep.major_id = s.schema_id where ep.name like 'tSQLt.%' UNION ALL SELECT 'tSQLt'"
        $SkipDBTests = Invoke-DbaQuery -SqlInstance $Sqlinstance -SqlCredential $SqlCredential -Query $q -Database $Database

        $task = "Collecting objects"
        Write-Progress -ParentId 1 -Activity " Function Parameters" -Status 'Progress->' -CurrentOperation $task -Id 2
    }

    process {
        if (Test-PSFFunctionInterrupt) { return }

        if (-not $InputObject -and -not $Function -and -not $SqlInstance) {
            Stop-PSFFunction -Message "You must pipe in an object or specify a Function"
            return
        }

        $objects = @()

        if ($InputObject) {
            $objects += $server.Databases[$Database].UserDefinedFunctions | Where-Object Name -in $InputObject | Where-Object Schema -NotIn $SkipDBTests.name | Select-Object Schema, Name, Parameters
        }
        else {
            $objects += $server.Databases[$Database].UserDefinedFunctions | Where-Object IsSystemObject -eq $false | Where-Object Schema -NotIn $SkipDBTests.name | Select-Object Schema, Name, Parameters
        }

        if ($Schema) {
            $objects = $objects | Where-Object Schema -in $Schema | Where-Object Schema -NotIn $SkipDBTests.name
        }

        if ($Function) {
            $objects = $objects | Where-Object Name -in $Function | Where-Object Schema -NotIn $SkipDBTests.name
        }


        $objectCount = $objects.Count
        $objectStep = 1

        if ($objectCount -ge 1) {
            foreach ($functionObject in $objects) {
                $task = "Creating function test $($objectStep) of $($objectCount)"
                Write-Progress -ParentId 1 -Activity "Creating..." -Status 'Progress->' -PercentComplete ($objectStep / $objectCount * 100) -CurrentOperation $task -Id 2

                $testName = "test If function $($functionObject.Schema).$($functionObject.Name) has the correct parameters"

                # Test if the name of the test does not become too long
                if ($testName.Length -gt 128) {
                    Stop-PSFFunction -Message "Name of the test is too long" -Target $testName
                }

                $fileName = Join-Path -Path $OutputPath -ChildPath "$($testName).sql"

                # Get the parameters
                $query = "SELECT pm.name AS ParameterName,
                        t.name AS DataType,
                        pm.max_length AS MaxLength,
                        pm.precision AS [Precision],
                        pm.scale AS Scale
                    FROM sys.parameters AS pm
                        INNER JOIN sys.sql_modules AS sm
                            ON sm.object_id = pm.object_id
                        INNER JOIN sys.objects AS o
                            ON sm.object_id = o.object_id
                        INNER JOIN sys.schemas AS s
                            ON s.schema_id = o.schema_id
                        INNER JOIN sys.types AS t
                            ON pm.system_type_id = t.system_type_id
                            AND pm.user_type_id = t.user_type_id
                    WHERE s.name = '$($functionObject.Schema)'
                        AND o.name = '$($functionObject.Name)'
                        AND pm.name <> '';"

                try {
                    $parameters = @()
                    $parameters += Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $Database -Query $query
                }
                catch {
                    Stop-PSFFunction -Message "Could not retrieve parameters for [$($functionObject.Schema)].[$($functionObject.Name)]" -Target $functionObject -Continue
                }

                if ($parameters.Count -ge 1) {
                    # Import the template
                    try {
                        $script = Get-Content -Path (Join-Path -Path $TemplateFolder -ChildPath "FunctionParameterTest.template")
                    }
                    catch {
                        Stop-PSFFunction -Message "Could not import test template 'FunctionParameterTest.template'" -Target $testName -ErrorRecord $_
                    }

                    $paramTextCollection = @()

                    # Loop through the parameters
                    foreach ($parameter in $parameters) {
                        $paramText = "`t('$($parameter.ParameterName)', '$($parameter.DataType)', $($parameter.MaxLength), $($parameter.Precision), $($parameter.Scale))"
                        $paramTextCollection += $paramText
                    }

                    # Replace the markers with the content
                    $script = $script.Replace("___TESTCLASS___", $TestClass)
                    $script = $script.Replace("___TESTNAME___", $testName)
                    $script = $script.Replace("___SCHEMA___", $functionObject.Schema)
                    $script = $script.Replace("___NAME___", $functionObject.Name)
                    $script = $script.Replace("___CREATOR___", $creator)
                    $script = $script.Replace("___DATE___", $date)
                    $script = $script.Replace("___PARAMETERS___", ($paramTextCollection -join ",`n") + ";")

                    # Write the test
                    if ($PSCmdlet.ShouldProcess("$($functionObject.Schema).$($functionObject.Name)", "Writing Function Parameter Test")) {
                        try {
                            Write-PSFMessage -Message "Creating function parameter test for function '$($functionObject.Schema).$($functionObject.Name)'"
                            $script | Out-File -FilePath $fileName

                            [PSCustomObject]@{
                                TestName = $testName
                                Category = "FunctionParameter"
                                Creator  = $creator
                                FileName = $fileName
                            }
                        }
                        catch {
                            Stop-PSFFunction -Message "Something went wrong writing the test" -Target $testName -ErrorRecord $_
                        }
                    }
                }
                else {
                    Write-PSFMessage -Message "Function $($functionObject.Schema).$($functionObject.Name) does not have any parameters. Skipping..."
                }

                $functionStep++
            }
        }
    }
}

function New-PSTGIndexColumnTest {
    <#
    .SYNOPSIS
        Function to test the columns for an index

    .DESCRIPTION
        The function will retrieve the current columns for an index and create a test for it

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

    .PARAMETER Index
        Index(es) to create tests for

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
        New-PSTGIndexColumnTest -Table $table -OutputPath $OutputPath

        Create a new index column test

    .EXAMPLE
        $tables | New-PSTGIndexColumnTest -OutputPath $OutputPath

        Create the tests using pipelines
    #>

    [CmdletBinding(SupportsShouldProcess)]

    param(
        [DbaInstanceParameter]$SqlInstance,
        [pscredential]$SqlCredential,
        [string]$Database,
        [string[]]$Schema,
        [string[]]$Table,
        [string[]]$Index,
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
        Write-Progress -ParentId 1 -Activity " Index Columns" -Status 'Progress->' -CurrentOperation $task -Id 2

        $tables = @()

        if ($Schema) {
            $tables += $server.Databases[$Database].Tables | Where-Object { $_.IsSystemObject -eq $false -and $_.Schema -in $Schema } | Where-Object Schema -NotIn $SkipDBTests.name | Select-Object Schema, Name, Indexes
        }
        else {
            $tables += $server.Databases[$Database].Tables | Where-Object { $_.IsSystemObject -eq $false } | Where-Object Schema -NotIn $SkipDBTests.name | Select-Object Schema, Name, Indexes
        }

        if ($Table) {
            $tables = $tables | Where-Object Name -in $Table | Where-Object Schema -NotIn $SkipDBTests.name
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
            $objects += $tables.Indexes | Where-Object Name -in $InputObject | Where-Object Schema -NotIn $SkipDBTests.name | Select-Object Name, IndexedColumns
        }
        else {
            $objects += $tables.Indexes | Where-Object Schema -NotIn $SkipDBTests.name | Select-Object Name, IndexedColumns
        }

        if ($Index) {
            $objects = $objects | Where-Object Name -in $Index | Where-Object Schema -NotIn $SkipDBTests.name
        }

        $objectCount = $objects.Count
        $objectStep = 1

        if ($objectCount -ge 1) {
            foreach ($indexObject in $objects) {
                $task = "Creating index column test $($objectStep) of $($objectCount)"
                Write-Progress -ParentId 1 -Activity "Creating..." -Status 'Progress->' -PercentComplete ($objectStep / $objectCount * 100) -CurrentOperation $task -Id 2

                $testName = "test If index $($indexObject.Name) has the correct columns"

                # Test if the name of the test does not become too long
                if ($testName.Length -gt 128) {
                    Stop-PSFFunction -Message "Name of the test is too long" -Target $testName
                }

                $fileName = Join-Path -Path $OutputPath -ChildPath "$($testName).sql"
                $date = Get-Date -Format (Get-culture).DateTimeFormat.ShortDatePattern
                $creator = $env:username

                # Import the template
                try {
                    $script = Get-Content -Path (Join-Path -Path $TemplateFolder -ChildPath "IndexColumnTest.template")
                }
                catch {
                    Stop-PSFFunction -Message "Could not import test template 'IndexColumnTest.template'" -Target $testName -ErrorRecord $_
                }

                # Get the columns
                $query = "SELECT col.name AS ColumnName,
                        st.name AS DataType,
                        col.max_length AS MaxLength,
                        col.precision AS [Precision],
                        col.scale AS Scale
                    FROM sys.indexes AS ind
                        INNER JOIN sys.index_columns AS ic
                            ON ind.object_id = ic.object_id
                            AND ind.index_id = ic.index_id
                        INNER JOIN sys.columns AS col
                            ON ic.object_id = col.object_id
                            AND ic.column_id = col.column_id
                        INNER JOIN sys.tables AS t
                            ON ind.object_id = t.object_id
                        LEFT JOIN sys.types AS st
                            ON st.user_type_id = col.user_type_id
                    WHERE ind.name = '$($indexObject.Name)';"

                try {
                    $columns = Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $Database -Query $query
                }
                catch {
                    Stop-PSFFunction -Message "Could not retrieve columns for [$($indexObject.Schema)].[$($indexObject.Name)]" -Target $indexObject -Continue
                }

                $columnTextCollection = @()

                # Loop through the columns
                foreach ($column in $columns) {
                    $columnText = "`t('$($column.ColumnName)', '$($column.DataType)', $($column.MaxLength), $($column.Precision), $($column.Scale))"
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
                if ($PSCmdlet.ShouldProcess("$($indexObject.Schema).$($indexObject.Name)", "Writing Index Column Test")) {
                    try {
                        Write-PSFMessage -Message "Creating index column test for index '$($indexObject.Name)'"
                        $script | Out-File -FilePath $fileName

                        [PSCustomObject]@{
                            TestName = $testName
                            Category = "IndexColumn"
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

function New-PSTGObjectExistenceTest {
    <#
    .SYNOPSIS
        Function to check if an object exists

    .DESCRIPTION
        The function will create a test to check for the existence of an object

    .PARAMETER SqlInstance
        The target SQL Server instance or instances. Server version must be SQL Server version 2012 or higher.

    .PARAMETER SqlCredential
        Login to the target instance using alternative credentials. Accepts PowerShell credentials (Get-Credential).

        Windows Authentication, SQL Server Authentication, Active Directory - Password, and Active Directory - Integrated are all supported.

        For MFA support, please use Connect-DbaInstance.

    .PARAMETER Database
        The database or databases to add.

    .PARAMETER Schema
        Filter the objects based on schema

    .PARAMETER Object
        The object(s) to create the tests for

    .PARAMETER OutputPath
        Path to output the test to

    .PARAMETER Creator
        The person that created the tests. By default the command will get the environment username

    .PARAMETER TemplateFolder
        Path to template folder. By default the internal templates folder will be used

    .PARAMETER TestClass
        Test class name to use for the test

    .PARAMETER InputObject
        Takes the parameters required from a Login object that has been piped into the command

    .PARAMETER WhatIf
        Shows what would happen if the command were to run. No actions are actually performed.

    .PARAMETER Confirm
        Prompts you for confirmation before executing any changing operations within the command.

    .PARAMETER EnableException
        By default, when something goes wrong we try to catch it, interpret it and give you a friendly warning message.
        This avoids overwhelming you with "sea of red" exceptions, but is inconvenient because it basically disables advanced scripting.
        Using this switch turns this "nice by default" feature off and enables you to catch exceptions with your own try/catch.

    .EXAMPLE
        New-PSTGObjectExistenceTest -Object $object -OutputPath $OutputPath

        Create a new object existence test

    .EXAMPLE
        $objects | New-PSTGObjectExistenceTest -OutputPath $OutputPath

        Create the tests using pipelines
    #>

    [CmdletBinding(SupportsShouldProcess)]

    param(
        [DbaInstanceParameter]$SqlInstance,
        [pscredential]$SqlCredential,
        [string]$Database,
        [string[]]$Schema,
        [string[]]$Object,
        [string]$OutputPath,
        [string]$Creator,
        [string]$TemplateFolder,
        [string]$TestClass,
        [parameter(ParameterSetName = "InputObject", ValueFromPipeline)]
        [object[]]$InputObject,
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

        $date = Get-Date -Format (Get-culture).DateTimeFormat.ShortDatePattern

        if (-not $Creator) {
            $Creator = $env:username
        }

        if (-not $TestClass) {
            $TestClass = "TestBasic"
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
            Stop-PSFFunction -Message "Database cannot be found on '$SqlInstance'" -Target $Database
        }

        $q = "select s.name from sys.schemas s join sys.extended_properties ep on ep.major_id = s.schema_id where ep.name like 'tSQLt.%' UNION ALL SELECT 'tSQLt'"
        $SkipDBTests = Invoke-DbaQuery -SqlInstance $Sqlinstance -SqlCredential $SqlCredential -Query $q -Database $Database
        
        $task = "Collecting objects"
        Write-Progress -ParentId 1 -Activity " Object Existence" -Status 'Progress->' -CurrentOperation $task -Id 2
    }

    process {
        if (Test-PSFFunctionInterrupt) { return }

        $objects = @()

        if ($InputObject) {
            # Get the extended stored procedures
            $objects += $server.Databases[$Database].ExtendedStoredProcedures | Where-Object { $_.Name -in $InputObject -and $_.IsSystemObject -eq $false } | Where-Object Schema -NotIn $SkipDBTests.name | Select-Object Schema, Name, @{Name = "ObjectType"; Expression = { "Extended Stored Procedure" } }

            # Get the sequences
            $objects += $server.Databases[$Database].Sequences | Where-Object Name -in $InputObject | Where-Object Schema -NotIn $SkipDBTests.name | Select-Object Schema, Name, @{Name = "ObjectType"; Expression = { "Sequence" } }

            # Get stored procedures
            $params = @{
                SqlInstance          = $SqlInstance
                SqlCredential        = $SqlCredential
                Database             = $Database
                Type                 = "StoredProcedure"
                ExcludeSystemObjects = $true
            }

            $objects += Get-DbaModule @params | Where-Object Name -in $InputObject | Where-Object SchemaName -NotIn $SkipDBTests.name | Select-Object @{Name = "Schema"; Expression = { $_.SchemaName } }, Name, @{Name = "ObjectType"; Expression = { "Stored Procedure" } }

            # Get tables
            $objects += $server.Databases[$Database].Tables | Where-Object Name -in $InputObject | Where-Object Shema -NotIn $SkipDBTests.name | Select-Object Schema, Name, @{Name = "ObjectType"; Expression = { "Table" } }

            # Get user defined data types
            $objects += $server.Databases[$Database].UserDefinedDataTypes | Where-Object { $_.Name -in $InputObject -and $_.IsSystemObject -eq $false } | Where-Object Schema -NotIn $SkipDBTests.name | Select-Object Schema, Name, @{Name = "ObjectType"; Expression = { "User Defined Data Type" } }

            # Get user defined functions
            $objects += $server.Databases[$Database].UserDefinedFunctions | Where-Object { $_.Name -in $InputObject -and $_.IsSystemObject -eq $false } | Where-Object Schema -NotIn $SkipDBTests.name | Select-Object Schema, Name, @{Name = "ObjectType"; Expression = { "User Defined Function" } }

            # Get user defined table types
            $objects += $server.Databases[$Database].UserDefinedTableTypes | Where-Object { $_.Name -in $InputObject -and $_.IsSystemObject -eq $false } | Where-Object Schema -NotIn $SkipDBTests.name | Select-Object Schema, Name, @{Name = "ObjectType"; Expression = { "User Defined Table Type" } }

            # Get views
            $params = @{
                SqlInstance          = $SqlInstance
                SqlCredential        = $SqlCredential
                Database             = $Database
                Type                 = "View"
                ExcludeSystemObjects = $true
            }

            $objects += Get-DbaModule @params | Where-Object Name -in $InputObject | Where-Object SchemaName -NotIn $SkipDBTests.name | Select-Object @{Name = "Schema"; Expression = { $_.SchemaName } }, Name, @{Name = "ObjectType"; Expression = { "View" } }
        }
        else {
            # Get the extended stored procedures
            $objects += $server.Databases[$Database].ExtendedStoredProcedures | Where-Object { $_.IsSystemObject -eq $false } | Where-Object Schema -NotIn $SkipDBTests.name | Select-Object Schema, Name, @{Name = "ObjectType"; Expression = { "Extended Stored Procedure" } }

            # Get sequences
            $objects += $server.Databases[$Database].Sequences | Where-Object Schema -NotIn $SkipDBTests.name | Select-Object Schema, Name, @{Name = "ObjectType"; Expression = { "Sequence" } }

            # Get stored procedures
            $params = @{
                SqlInstance          = $SqlInstance
                SqlCredential        = $SqlCredential
                Database             = $Database
                Type                 = "StoredProcedure"
                ExcludeSystemObjects = $true
            }

            $objects += Get-DbaModule @params | Where-Object SchemaName -NotIn $SkipDBTests.name | Select-Object @{Name = "Schema"; Expression = { $_.SchemaName } }, Name, @{Name = "ObjectType"; Expression = { "Stored Procedure" } }

            # Get tables
            $objects += $server.Databases[$Database].Tables | Where-Object Schema -NotIn $SkipDBTests.name | Select-Object Schema, Name, @{Name = "ObjectType"; Expression = { "Table" } }

            # Get user defined data types
            $objects += $server.Databases[$Database].UserDefinedDataTypes | Where-Object Schema -NotIn $SkipDBTests.name | Where-Object { $_.IsSystemObject -eq $false } | Select-Object Schema, Name, @{Name = "ObjectType"; Expression = { "User Defined Data Type" } }

            # Get user defined functions
            $objects += $server.Databases[$Database].UserDefinedFunctions | Where-Object { $_.IsSystemObject -eq $false } | Where-Object Schema -NotIn $SkipDBTests.name | Select-Object Schema, Name, @{Name = "ObjectType"; Expression = { "User Defined Function" } }

            # Get user defined table types
            $objects += $server.Databases[$Database].UserDefinedTableTypes | Where-Object { $_.IsSystemObject -eq $false } | Where-Object Schema -NotIn $SkipDBTests.name | Select-Object Schema, Name, @{Name = "ObjectType"; Expression = { "User Defined Table Type" } }

            # Get views
            $params = @{
                SqlInstance          = $SqlInstance
                SqlCredential        = $SqlCredential
                Database             = $Database
                Type                 = "View"
                ExcludeSystemObjects = $true
            }

            $objects += Get-DbaModule @params | Where-Object SchemaName -NotIn $SkipDBTests.name | Select-Object @{Name = "Schema"; Expression = { $_.SchemaName } }, Name, @{Name = "ObjectType"; Expression = { "View" } }
        }

        if ($Schema) {
            $objects = $objects | Where-Object Schema -in $Schema | Where-Object Schema -NotIn $SkipDBTests.name
        }

        if ($Object) {
            $objects = $objects | Where-Object Name -in $Object | Where-Object Schema -NotIn $SkipDBTests.name
        }

        $objectCount = $objects.Count
        $objectStep = 1

        if ($objectCount -ge 1) {
            foreach ($obj in $objects) {
                $task = "Creating object existence test $($objectStep) of $($objectCount)"
                Write-Progress -ParentId 1 -Activity "Creating..." -Status 'Progress->' -PercentComplete ($objectStep / $objectCount * 100) -CurrentOperation $task -Id 2

                if ($null -eq $obj.Schema) {
                    $testName = "test If $(($obj.ObjectType).ToLower()) $($obj.Name) exists"
                }
                else {
                    $testName = "test If $(($obj.ObjectType).ToLower()) $($obj.Schema)`.$($obj.Name) exists"
                }

                # Test if the name of the test does not become too long
                if ($testName.Length -gt 128) {
                    Stop-PSFFunction -Message "Name of the test is too long" -Target $testName
                }

                $fileName = Join-Path -Path $OutputPath -ChildPath "$($testName).sql"

                # Import the template
                try {
                    $script = Get-Content -Path (Join-Path -Path $TemplateFolder -ChildPath "ObjectExistence.template")
                }
                catch {
                    Stop-PSFFunction -Message "Could not import test template 'ObjectExistence.template'" -Target $testName -ErrorRecord $_
                }

                # Replace the markers with the content
                $script = $script.Replace("___TESTCLASS___", $TestClass)
                $script = $script.Replace("___TESTNAME___", $testName)
                $script = $script.Replace("___OBJECTTYPE___", $($obj.ObjectType).ToLower())
                $script = $script.Replace("___SCHEMA___", $obj.Schema)
                $script = $script.Replace("___NAME___", $obj.Name)
                $script = $script.Replace("___CREATOR___", $creator)
                $script = $script.Replace("___DATE___", $date)

                # Write the test
                if ($PSCmdlet.ShouldProcess("$testName", "Writing Object Existence Test")) {
                    try {
                        Write-PSFMessage -Message "Creating existence test for $(($obj.ObjectType).ToLower()) '$($obj.Schema).$($obj.Name)'" -Level Verbose
                        $script | Out-File -FilePath $fileName

                        [PSCustomObject]@{
                            TestName = $testName
                            Category = "ObjectExistence"
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

function New-PSTGProcedureParameterTest {
    <#
    .SYNOPSIS
        Function to create procedure tests

    .DESCRIPTION
        The function will collect the parameter(s) of the procedure(s) and create the test

    .PARAMETER SqlInstance
        The target SQL Server instance or instances. Server version must be SQL Server version 2012 or higher.

    .PARAMETER SqlCredential
        Login to the target instance using alternative credentials. Accepts PowerShell credentials (Get-Credential).

        Windows Authentication, SQL Server Authentication, Active Directory - Password, and Active Directory - Integrated are all supported.

        For MFA support, please use Connect-DbaInstance.

    .PARAMETER Database
        The database or databases to add.

    .PARAMETER Schema
        Filter the stored procedures based on schema

    .PARAMETER Procedure
        Procedure(s) to create tests for

    .PARAMETER OutputPath
        Path to output the test to

    .PARAMETER Creator
        The person that created the tests. By default the command will get the environment username

    .PARAMETER TemplateFolder
        Path to template folder. By default the internal templates folder will be used

    .PARAMETER TestClass
        Test class name to use for the test

    .PARAMETER InputObject
        Takes the parameters required from a Procedure object that has been piped into the command

    .PARAMETER WhatIf
        Shows what would happen if the command were to run. No actions are actually performed.

    .PARAMETER Confirm
        Prompts you for confirmation before executing any changing operations within the command.

    .PARAMETER EnableException
        By default, when something goes wrong we try to catch it, interpret it and give you a friendly warning message.
        This avoids overwhelming you with "sea of red" exceptions, but is inconvenient because it basically disables advanced scripting.
        Using this switch turns this "nice by default" feature off and enables you to catch exceptions with your own try/catch.

    .EXAMPLE
        New-PSTGProcedureParameterTest -Procedure $procedure -OutputPath $OutputPath

        Create a new procedure parameter test

    .EXAMPLE
        $procedures | New-PSTGProcedureParameterTest -OutputPath $OutputPath

        Create the tests using pipelines
    #>

    [CmdletBinding(SupportsShouldProcess)]

    param(
        [DbaInstanceParameter]$SqlInstance,
        [pscredential]$SqlCredential,
        [string]$Database,
        [string[]]$Schema,
        [string[]]$Procedure,
        [string]$OutputPath,
        [string]$Creator,
        [string]$TemplateFolder,
        [string]$TestClass,
        [parameter(ParameterSetName = "InputObject", ValueFromPipeline)]
        [Microsoft.SqlServer.Management.Smo.StoredProcedure[]]$InputObject,
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
            Stop-PSFFunction -Message "Could not access output path" -Category ResourceUnavailable -Target $OutputPath
        }

        # Check the template folder
        if (-not $TemplateFolder) {
            $TemplateFolder = Join-Path -Path ($script:ModuleRoot) -ChildPath "internal\templates"
        }

        if (-not (Test-Path -Path $TemplateFolder)) {
            try {
                $null = New-Item -Path $OutputPath -ItemType Directory
            }
            catch {
                Stop-PSFFunction -Message "Something went wrong creating the output directory" -Target $OutputPath -ErrorRecord $_
            }
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
            Stop-PSFFunction -Message "Database cannot be found on '$SqlInstance'" -Target $Database
        }

        $q = "select s.name from sys.schemas s join sys.extended_properties ep on ep.major_id = s.schema_id where ep.name like 'tSQLt.%' UNION ALL SELECT 'tSQLt'"
        $SkipDBTests = Invoke-DbaQuery -SqlInstance $Sqlinstance -SqlCredential $SqlCredential -Query $q -Database $Database

        $task = "Collecting objects"
        Write-Progress -ParentId 1 -Activity " Stored Procedure Parameters" -Status 'Progress->' -CurrentOperation $task -Id 2
    }

    process {
        if (Test-PSFFunctionInterrupt) { return }

        if (-not $InputObject -and -not $Procedure -and -not $SqlInstance) {
            Stop-PSFFunction -Message "You must pipe in an object or specify a Procedure"
            return
        }

        $objects = @()

        if ($InputObject) {
            $objects += Get-DbaModule -SqlInstance $SqlInstance -Database $Database -Type StoredProcedure -ExcludeSystemObjects | Where-Object Name -in $InputObject | Where-Object SchemaName -NotIn $SkipDBTests.name | Select-Object SchemaName, Name
        }
        else {
            $objects += Get-DbaModule -SqlInstance $SqlInstance -Database $Database -Type StoredProcedure -ExcludeSystemObjects | Where-Object SchemaName -NotIn $SkipDBTests.name | Select-Object SchemaName, Name
        }

        if ($Schema) {
            $objects = $objects | Where-Object SchemaName -in $Schema | Where-Object SchemaName -NotIn $SkipDBTests.name
        }

        if ($Procedure) {
            $objects = $objects | Where-Object Name -in $Procedure | Where-Object SchemaName -NotIn $SkipDBTests.name
        }

        $objectCount = $objects.Count
        $objectStep = 1

        if ($objectCount -ge 1) {
            foreach ($procedureObject in $objects) {

                $procedureObject = $server.Databases[$Database].StoredProcedures | Where-Object { $_.Schema -eq $procedureObject.SchemaName -and $_.Name -eq $procedureObject.Name }

                $task = "Creating procedure test $($objectStep) of $($objectCount)"
                Write-Progress -ParentId 1 -Activity "Creating..." -Status 'Progress->' -PercentComplete ($objectStep / $objectCount * 100) -CurrentOperation $task -Id 2

                $testName = "test If stored procedure $($procedureObject.Schema).$($procedureObject.Name) has the correct parameters"

                # Test if the name of the test does not become too long
                if ($testName.Length -gt 128) {
                    Stop-PSFFunction -Message "Name of the test is too long" -Target $testName
                }

                $fileName = Join-Path -Path $OutputPath -ChildPath "$($testName).sql"
                $date = Get-Date -Format (Get-culture).DateTimeFormat.ShortDatePattern
                $creator = $env:username

                # Get the parameters
                $query = "SELECT pm.name AS ParameterName,
                        t.name AS DataType,
                        pm.max_length AS MaxLength,
                        pm.precision AS [Precision],
                        pm.scale AS Scale
                FROM sys.parameters AS pm
                    INNER JOIN sys.procedures AS ps
                        ON pm.object_id = ps.object_id
                    INNER JOIN sys.schemas AS s
                        ON s.schema_id = ps.schema_id
                    INNER JOIN sys.types AS t
                        ON pm.system_type_id = t.system_type_id
                            AND pm.user_type_id = t.user_type_id
                WHERE s.name = '$($procedureObject.Schema)'
                    AND ps.name = '$($procedureObject.Name)';"

                try {
                    $parameters = @()
                    $parameters += Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $Database -Query $query
                }
                catch {
                    Stop-PSFFunction -Message "Could not retrieve parameters for [$($procedureObject.Schema)].[$($procedureObject.Name)]" -Target $procedureObject -Continue
                }

                if ($parameters.Count -ge 1) {
                    # Import the template
                    try {
                        $script = Get-Content -Path (Join-Path -Path $TemplateFolder -ChildPath "ProcedureParameterTest.template")
                    }
                    catch {
                        Stop-PSFFunction -Message "Could not import test template 'ProcedureParameterTest.template'" -Target $testName -ErrorRecord $_
                    }

                    $paramTextCollection = @()

                    # Loop through the parameters
                    foreach ($parameter in $parameters) {
                        $paramText = "`t('$($parameter.ParameterName)', '$($parameter.DataType)', $($parameter.MaxLength), $($parameter.Precision), $($parameter.Scale))"
                        $paramTextCollection += $paramText
                    }

                    # Replace the markers with the content
                    $script = $script.Replace("___TESTCLASS___", $TestClass)
                    $script = $script.Replace("___TESTNAME___", $testName)
                    $script = $script.Replace("___SCHEMA___", $procedureObject.Schema)
                    $script = $script.Replace("___NAME___", $procedureObject.Name)
                    $script = $script.Replace("___CREATOR___", $creator)
                    $script = $script.Replace("___DATE___", $date)
                    $script = $script.Replace("___PARAMETERS___", ($paramTextCollection -join ",`n") + ";")

                    # Write the test
                    if ($PSCmdlet.ShouldProcess("$($procedureObject.Schema).$($procedureObject.Name)", "Writing Procedure Parameter Test")) {
                        try {
                            Write-PSFMessage -Message "Creating procedure parameter test for procedure '$($procedureObject.Schema).$($procedureObject.Name)'"
                            $script | Out-File -FilePath $fileName

                            [PSCustomObject]@{
                                TestName = $testName
                                Category = "ProcedureParameter"
                                Creator  = $creator
                                FileName = $fileName
                            }
                        }
                        catch {
                            Stop-PSFFunction -Message "Something went wrong writing the test" -Target $testName -ErrorRecord $_
                        }
                    }
                }
                else {
                    Write-PSFMessage -Message "Procedure $($procedureObject.Schema).$($procedureObject.Name) does not have any parameters. Skipping..."
                }

                $objectStep++
            }
        }
    }
}

function New-PSTGTableColumnTest {
    <#
    .SYNOPSIS
        Function to test thee columns for a table

    .DESCRIPTION
        The function will retrieve the current columns for a table and create a test for it

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
        New-PSTGTableColumnTest -Table $table -OutputPath $OutputPath

        Create a new table column test

    .EXAMPLE
        $tables | New-PSTGTableColumnTest -OutputPath $OutputPath

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
        [Microsoft.SqlServer.Management.Smo.Table[]]$InputObject,
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
        Write-Progress -ParentId 1 -Activity " Table Columns" -Status 'Progress->' -CurrentOperation $task -Id 2
    }

    process {
        if (Test-PSFFunctionInterrupt) { return }

        if (-not $InputObject -and -not $Table -and -not $SqlInstance) {
            Stop-PSFFunction -Message "You must pipe in an object or specify a Table"
            return
        }

        $objects = @()

        if ($InputObject) {
            $objects += $server.Databases[$Database].Tables | Where-Object { $_.IsSystemObject -eq $false -and $_.Name -in $InputObject } | Where-Object Schema -NotIn $SkipDBTests.name | Select-Object Schema, Name, Columns
        }
        else {
            $objects += $server.Databases[$Database].Tables | Where-Object { $_.IsSystemObject -eq $false } | Where-Object Schema -NotIn $SkipDBTests.name | Select-Object Schema, Name, Columns
        }

        if ($Schema) {
            $objects = $objects | Where-Object Schema -in $Schema | Where-Object Schema -NotIn $SkipDBTests.name
        }

        if ($Table) {
            $objects = $objects | Where-Object Name -in $Table | Where-Object Schema -NotIn $SkipDBTests.name
        }

        $objectCount = $objects.Count
        $objectStep = 1

        if ($objectCount -ge 1) {
            foreach ($tableObject in $objects) {
                $task = "Creating table column test $($objectStep) of $($objectCount)"
                Write-Progress -ParentId 1 -Activity "Creating..." -Status 'Progress->' -PercentComplete ($objectStep / $objectCount * 100) -CurrentOperation $task -Id 2

                $testName = "test If table $($tableObject.Schema).$($tableObject.Name) has the correct columns"

                # Test if the name of the test does not become too long
                if ($testName.Length -gt 128) {
                    Stop-PSFFunction -Message "Name of the test is too long" -Target $testName
                }

                $fileName = Join-Path -Path $OutputPath -ChildPath "$($testName).sql"
                $date = Get-Date -Format (Get-culture).DateTimeFormat.ShortDatePattern
                $creator = $env:username

                # Import the template
                try {
                    $script = Get-Content -Path (Join-Path -Path $TemplateFolder -ChildPath "TableColumnTest.template")
                }
                catch {
                    Stop-PSFFunction -Message "Could not import test template 'TableColumnTest.template'" -Target $testName -ErrorRecord $_
                }

                # Get the columns
                $query = "SELECT c.name AS ColumnName,
                            st.name AS DataType,
                            c.max_length AS MaxLength,
                            c.precision AS [Precision],
                            c.scale AS Scale
                    FROM sys.columns AS c
                        INNER JOIN sys.tables AS t
                            ON t.object_id = c.object_id
                        INNER JOIN sys.schemas AS s
                            ON s.schema_id = t.schema_id
                        LEFT JOIN sys.types AS st
                            ON st.user_type_id = c.user_type_id
                    WHERE t.type = 'U'
                        AND s.name = '$($tableObject.Schema)'
                        AND t.name = '$($tableObject.Name)'
                    ORDER BY t.name,
                            c.name;"

                try {
                    $columns = Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $Database -Query $query
                }
                catch {
                    Stop-PSFFunction -Message "Could not retrieve columns for [$($tableObject.Schema)].[$($tableObject.Name)]" -Target $tableObject -Continue
                }

                $columnTextCollection = @()

                # Loop through the columns
                foreach ($column in $columns) {
                    $columnText = "`t('$($column.ColumnName)', '$($column.DataType)', $($column.MaxLength), $($column.Precision), $($column.Scale))"
                    $columnTextCollection += $columnText
                }

                # Replace the markers with the content
                $script = $script.Replace("___TESTCLASS___", $TestClass)
                $script = $script.Replace("___TESTNAME___", $testName)
                $script = $script.Replace("___SCHEMA___", $tableObject.Schema)
                $script = $script.Replace("___NAME___", $tableObject.Name)
                $script = $script.Replace("___CREATOR___", $creator)
                $script = $script.Replace("___DATE___", $date)
                $script = $script.Replace("___COLUMNS___", ($columnTextCollection -join ",`n") + ";")

                # Write the test
                if ($PSCmdlet.ShouldProcess("$($tableObject.Schema).$($tableObject.Name)", "Writing Table Column Test")) {
                    try {
                        Write-PSFMessage -Message "Creating table column test for table '$($tableObject.Schema).$($tableObject.Name)'"
                        $script | Out-File -FilePath $fileName

                        [PSCustomObject]@{
                            TestName = $testName
                            Category = "TableColumn"
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

function New-PSTGTableConstraintTest {
    <#
    .SYNOPSIS
        Function to test the constraints in a table

    .DESCRIPTION
        The function will retrieve the constraints for a table and create a test for it

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
        New-PSTGTableConstraintTest -Table $table -OutputPath $OutputPath

        Create a new constraint test

    .EXAMPLE
        $tables | New-PSTGTableConstraintTest -OutputPath $OutputPath

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
        [Microsoft.SqlServer.Management.Smo.Table[]]$InputObject,
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
        Write-Progress -ParentId 1 -Activity " Table Columns" -Status 'Progress->' -CurrentOperation $task -Id 2
    }

    process {
        if (Test-PSFFunctionInterrupt) { return }

        if (-not $InputObject -and -not $Table -and -not $SqlInstance) {
            Stop-PSFFunction -Message "You must pipe in an object or specify a Table"
            return
        }

        $objects = @()

        if ($InputObject) {
            $objects += $server.Databases[$Database].Tables | Where-Object { $_.IsSystemObject -eq $false -and $_.Name -in $InputObject } | Where-Object Schema -NotIn $SkipDBTests.name | Select-Object Schema, Name, Columns
        }
        else {
            $objects += $server.Databases[$Database].Tables | Where-Object { $_.IsSystemObject -eq $false } | Where-Object Schema -NotIn $SkipDBTests.name | Select-Object Schema, Name, Columns
        }

        if ($Schema) {
            [array]$objects = $objects | Where-Object Schema -in $Schema | Where-Object Schema -NotIn $SkipDBTests.name
        }

        if ($Table) {
            [array]$objects = $objects | Where-Object Name -in $Table | Where-Object Schema -NotIn $SkipDBTests.name
        }

        $objectCount = $objects.Count
        $objectStep = 1

        if ($objectCount -ge 1) {
            foreach ($object in $objects) {
                $task = "Creating table constraint test $($objectStep) of $($objectCount)"
                Write-Progress -ParentId 1 -Activity "Creating..." -Status 'Progress->' -PercentComplete ($objectStep / $objectCount * 100) -CurrentOperation $task -Id 2

                $testName = "test If table $($object.Schema).$($object.Name) has the correct constraints"

                # Test if the name of the test does not become too long
                if ($testName.Length -gt 128) {
                    Stop-PSFFunction -Message "Name of the test is too long" -Target $testName
                }

                $fileName = Join-Path -Path $OutputPath -ChildPath "$($testName).sql"
                $date = Get-Date -Format (Get-culture).DateTimeFormat.ShortDatePattern
                $creator = $env:username

                # Import the template
                try {
                    $script = Get-Content -Path (Join-Path -Path $TemplateFolder -ChildPath "TableConstraintTest.template")
                }
                catch {
                    Stop-PSFFunction -Message "Could not import test template 'TableConstraintTest.template'" -Target $testName -ErrorRecord $_
                }

                # Get the columns
                $query = "SELECT s.name AS [SchemaName],
                        t.name AS [TableName],
                        OBJECT_NAME(o.OBJECT_ID) AS [ConstraintName],
                        o.type_desc AS ConstraintType
                    FROM sys.objects as o
                        inner join sys.schemas as s
                        on s.schema_id = o.schema_id
                        INNER JOIN sys.tables as t
                        on t.object_id = o.parent_object_id
                    WHERE o.type_desc LIKE '%CONSTRAINT'
                        AND s.name = '$($object.Schema)'
                        AND t.name = '$($object.Name)'
                    ORDER BY ConstraintName"

                try {
                    $constraints = Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $Database -Query $query
                }
                catch {
                    Stop-PSFFunction -Message "Could not retrieve columns for [$($object.Schema)].[$($object.Name)]" -Target $object -Continue
                }

                $constraintTextCollection = @()

                # Loop through the columns
                foreach ($constr in $constraints) {
                    $constraintText = "`t('$($constr.SchemaName)', '$($constr.TableName)', '$($constr.ConstraintName)', '$($constr.ConstraintType)')"
                    $constraintTextCollection += $constraintText
                }

                # Replace the markers with the content
                $script = $script.Replace("___TESTCLASS___", $TestClass)
                $script = $script.Replace("___TESTNAME___", $testName)
                $script = $script.Replace("___SCHEMA___", $object.Schema)
                $script = $script.Replace("___NAME___", $object.Name)
                $script = $script.Replace("___CREATOR___", $creator)
                $script = $script.Replace("___DATE___", $date)
                $script = $script.Replace("___COLUMNS___", ($constraintTextCollection -join ",`n") + ";")

                # Write the test
                if ($PSCmdlet.ShouldProcess("$($object.Schema).$($object.Name)", "Writing Table Column Test")) {
                    try {
                        Write-PSFMessage -Message "Creating table constraint test for table '$($object.Schema).$($object.Name)'"
                        $script | Out-File -FilePath $fileName

                        [PSCustomObject]@{
                            TestName = $testName
                            Category = "TableColumn"
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

function New-PSTGTableIndexTest {
    <#
    .SYNOPSIS
        Function to test the indexes for a table

    .DESCRIPTION
        The function will retrieve the current indexes for a table and create a test for it

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
        New-PSTGTableIndexTest -Table $table -OutputPath $OutputPath

        Create a new table column test

    .EXAMPLE
        $tables | New-PSTGTableIndexTest -OutputPath $OutputPath

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
        [Microsoft.SqlServer.Management.Smo.Table[]]$InputObject,
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
        Write-Progress -ParentId 1 -Activity " Table Columns" -Status 'Progress->' -CurrentOperation $task -Id 2
    }

    process {
        if (Test-PSFFunctionInterrupt) { return }

        if (-not $InputObject -and -not $Table -and -not $SqlInstance) {
            Stop-PSFFunction -Message "You must pipe in an object or specify a Table"
            return
        }

        $objects = @()

        if ($InputObject) {
            $objects += $server.Databases[$Database].Tables | Where-Object { $_.IsSystemObject -eq $false -and $_.Name -in $InputObject } | Where-Object Schema -NotIn $SkipDBTests.name | Select-Object Schema, Name, Indexes
        }
        else {
            $objects += $server.Databases[$Database].Tables | Where-Object { $_.IsSystemObject -eq $false } | Where-Object Schema -NotIn $SkipDBTests.name | Select-Object Schema, Name, Indexes
        }

        if ($Schema) {
            $objects = $objects | Where-Object Schema -in $Schema | Where-Object Schema -NotIn $SkipDBTests.name
        }

        if ($Table) {
            $objects = $objects | Where-Object Name -in $Table | Where-Object Schema -NotIn $SkipDBTests.name
        }

        $objectCount = $objects.Count
        $objectStep = 1

        if ($objectCount -ge 1) {
            foreach ($tableObject in $objects) {
                if ($tableObject.Indexes.Count -ge 1) {
                    $task = "Creating index column test $($objectStep) of $($objectCount)"
                    Write-Progress -ParentId 1 -Activity "Creating..." -Status 'Progress->' -PercentComplete ($objectStep / $objectCount * 100) -CurrentOperation $task -Id 2

                    $testName = "test If table $($tableObject.Schema).$($tableObject.Name) has the correct indexes"

                    # Test if the name of the test does not become too long
                    if ($testName.Length -gt 128) {
                        Stop-PSFFunction -Message "Name of the test is too long" -Target $testName
                    }

                    $fileName = Join-Path -Path $OutputPath -ChildPath "$($testName).sql"
                    $date = Get-Date -Format (Get-culture).DateTimeFormat.ShortDatePattern
                    $creator = $env:username

                    # Import the template
                    try {
                        $script = Get-Content -Path (Join-Path -Path $TemplateFolder -ChildPath "TableIndexTest.template")
                    }
                    catch {
                        Stop-PSFFunction -Message "Could not import test template 'TableIndexTest.template'" -Target $testName -ErrorRecord $_
                    }

                    # Get the columns
                    $query = "SELECT ind.name AS Name
                        FROM sys.indexes ind
                            INNER JOIN sys.tables t
                                ON ind.object_id = t.object_id
                            INNER JOIN sys.schemas AS s
                                ON s.schema_id = t.schema_id
                        WHERE s.name = '$($tableObject.Schema)'
                            AND t.name = '$($tableObject.Name)'
                            AND ind.Name IS NOT NULL;"

                    try {
                        $indexes = Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $Database -Query $query
                    }
                    catch {
                        Stop-PSFFunction -Message "Could not retrieve indexes for [$($tableObject.Schema)].[$($tableObject.Name)]" -Target $tableObject -Continue
                    }

                    $indexTextCollection = @()

                    # Loop through the columns
                    foreach ($index in $indexes) {
                        $indexText = "`t('$($index.Name)')"
                        $indexTextCollection += $indexText
                    }

                    # Replace the markers with the content
                    $script = $script.Replace("___TESTCLASS___", $TestClass)
                    $script = $script.Replace("___TESTNAME___", $testName)
                    $script = $script.Replace("___SCHEMA___", $tableObject.Schema)
                    $script = $script.Replace("___NAME___", $tableObject.Name)
                    $script = $script.Replace("___CREATOR___", $creator)
                    $script = $script.Replace("___DATE___", $date)
                    $script = $script.Replace("___INDEXES___", ($indexTextCollection -join ",`n") + ";")

                    # Write the test
                    if ($PSCmdlet.ShouldProcess("$($tableObject.Schema).$($tableObject.Name)", "Writing Table Index Test")) {
                        try {
                            Write-PSFMessage -Message "Creating table index test for table '$($tableObject.Schema).$($tableObject.Name)'"
                            $script | Out-File -FilePath $fileName

                            [PSCustomObject]@{
                                TestName = $testName
                                Category = "TableIndex"
                                Creator  = $creator
                                FileName = $fileName
                            }
                        }
                        catch {
                            Stop-PSFFunction -Message "Something went wrong writing the test" -Target $testName -ErrorRecord $_
                        }
                    }
                }

                $objectStep++
            }
        }
    }
}

function New-PSTGViewColumnTest {
    <#
    .SYNOPSIS
        Function to create view column tests

    .DESCRIPTION
        The function will retrieve the columns for a view and create a test for it

    .PARAMETER SqlInstance
        The target SQL Server instance or instances. Server version must be SQL Server version 2012 or higher.

    .PARAMETER SqlCredential
        Login to the target instance using alternative credentials. Accepts PowerShell credentials (Get-Credential).

        Windows Authentication, SQL Server Authentication, Active Directory - Password, and Active Directory - Integrated are all supported.

        For MFA support, please use Connect-DbaInstance.

    .PARAMETER Database
        The database or databases to add.

    .PARAMETER Schema
        Filter the views based on schema

    .PARAMETER View
        View(s) to create tests forr

    .PARAMETER OutputPath
        Path to output the test to

    .PARAMETER Creator
        The person that created the tests. By default the command will get the environment username

    .PARAMETER TemplateFolder
        Path to template folder. By default the internal templates folder will be used

    .PARAMETER TestClass
        Test class name to use for the test

    .PARAMETER InputObject
        Takes the parameters required from a View object that has been piped into the command

    .PARAMETER WhatIf
        Shows what would happen if the command were to run. No actions are actually performed.

    .PARAMETER Confirm
        Prompts you for confirmation before executing any changing operations within the command.

    .PARAMETER EnableException
        By default, when something goes wrong we try to catch it, interpret it and give you a friendly warning message.
        This avoids overwhelming you with "sea of red" exceptions, but is inconvenient because it basically disables advanced scripting.
        Using this switch turns this "nice by default" feature off and enables you to catch exceptions with your own try/catch.

    .EXAMPLE
        New-PSTGViewColumnTest -View $view -OutputPath $OutputPath

        Create a new view column test

    .EXAMPLE
        $views | New-PSTGViewColumnTest -OutputPath $OutputPath

        Create the tests using pipelines


    #>

    [CmdletBinding(SupportsShouldProcess)]

    param(
        [DbaInstanceParameter]$SqlInstance,
        [pscredential]$SqlCredential,
        [string]$Database,
        [string[]]$Schema,
        [string[]]$View,
        [string]$OutputPath,
        [string]$Creator,
        [string]$TemplateFolder,
        [string]$TestClass,
        [parameter(ParameterSetName = "InputObject", ValueFromPipeline)]
        [object[]]$InputObject,
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
            Stop-PSFFunction -Message "Database cannot be found on '$SqlInstance'" -Target $Database
        }

        $q = "select s.name from sys.schemas s join sys.extended_properties ep on ep.major_id = s.schema_id where ep.name like 'tSQLt.%' UNION ALL SELECT 'tSQLt'"
        $SkipDBTests = Invoke-DbaQuery -SqlInstance $Sqlinstance -SqlCredential $SqlCredential -Query $q -Database $Database

        $task = "Collecting objects"
        Write-Progress -ParentId 1 -Activity " View Columns" -Status 'Progress->' -CurrentOperation $task -Id 2
    }

    process {
        if (Test-PSFFunctionInterrupt) { return }

        if (-not $InputObject -and -not $View -and -not $SqlInstance) {
            Stop-PSFFunction -Message "You must pipe in an object or specify a View"
            return
        }

        $objects = @()

        if ($InputObject) {
            $objects += $server.Databases[$Database].Views | Where-Object Name -in $InputObject | Where-Object Schema -NotIn $SkipDBTests.name | Select-Object Schema, Name, Columns
        }
        else {
            $objects += $server.Databases[$Database].Views | Where-Object IsSystemObject -eq $false | Where-Object Schema -NotIn $SkipDBTests.name | Select-Object Schema, Name, Columns
        }

        if ($Schema) {
            $objects = $objects | Where-Object Schema -in $Schema | Where-Object Schema -NotIn $SkipDBTests.name
        }

        if ($View) {
            $objects = $objects | Where-Object Name -in $View | Where-Object Schema -NotIn $SkipDBTests.name
        }

        $objectCount = $objects.Count
        $objectStep = 1

        if ($objectCount -ge 1) {
            foreach ($viewObject in $objects) {
                $task = "Creating view test $($objectStep) of $($objectCount)"
                Write-Progress -ParentId 1 -Activity "Creating..." -Status 'Progress->' -PercentComplete ($objectStep / $objectCount * 100) -CurrentOperation $task -Id 2

                $testName = "test If view $($viewObject.Schema).$($viewObject.Name) has the correct columns"

                # Test if the name of the test does not become too long
                if ($testName.Length -gt 128) {
                    Stop-PSFFunction -Message "Name of the test is too long" -Target $testName
                }

                $fileName = Join-Path -Path $OutputPath -ChildPath "$($testName).sql"
                $date = Get-Date -Format (Get-culture).DateTimeFormat.ShortDatePattern
                $creator = $env:username

                # Import the template
                try {
                    $script = Get-Content -Path (Join-Path -Path $TemplateFolder -ChildPath "ViewColumnTest.template")
                }
                catch {
                    Stop-PSFFunction -Message "Could not import test template 'ViewColumnTest.template'" -Target $testName -ErrorRecord $_
                }

                # Get the columns
                $query = "SELECT c.name AS ColumnName,
                        st.name AS DataType,
                        c.max_length AS MaxLength,
                        c.precision AS [Precision],
                        c.scale AS Scale
                    FROM sys.columns AS c
                        INNER JOIN sys.views AS v
                            ON v.object_id = c.object_id
                        INNER JOIN sys.schemas AS s
                            ON s.schema_id = v.schema_id
                        LEFT JOIN sys.types AS st
                            ON st.user_type_id = c.user_type_id
                    WHERE v.type = 'V'
                        AND s.name = '$($viewObject.Schema)'
                        AND v.name = '$($viewObject.Name)'
                    ORDER BY v.name,
                            c.name;"

                try {
                    $columns = Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $Database -Query $query
                }
                catch {
                    Stop-PSFFunction -Message "Could not retrieve columns for [$($viewObject.Schema)].[$($viewObject.Name)]" -Target $viewObject -Continue
                }

                $columnTextCollection = @()

                # Loop through the columns
                foreach ($column in $columns) {
                    $columnText = "`t('$($column.ColumnName)', '$($column.DataType)', $($column.MaxLength), $($column.Precision), $($column.Scale))"
                    $columnTextCollection += $columnText
                }

                # Replace the markers with the content
                $script = $script.Replace("___TESTCLASS___", $TestClass)
                $script = $script.Replace("___TESTNAME___", $testName)
                $script = $script.Replace("___SCHEMA___", $viewObject.Schema)
                $script = $script.Replace("___NAME___", $viewObject.Name)
                $script = $script.Replace("___CREATOR___", $creator)
                $script = $script.Replace("___DATE___", $date)
                $script = $script.Replace("___COLUMNS___", ($columnTextCollection -join ",`n") + ";")

                # Write the test
                if ($PSCmdlet.ShouldProcess("$($viewObject.Schema).$($viewObject.Name)", "Writing View Column Test")) {
                    try {
                        Write-PSFMessage -Message "Creating view column test for table '$($viewObject.Schema).$($viewObject.Name)'"
                        $script | Out-File -FilePath $fileName

                        [PSCustomObject]@{
                            TestName = $testName
                            Category = "ViewColumn"
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

<#
This is an example configuration file

By default, it is enough to have a single one of them,
however if you have enough configuration settings to justify having multiple copies of it,
feel totally free to split them into multiple files.
#>

<#
# Example Configuration
Set-PSFConfig -Module 'PStSQLtTestGenerator' -Name 'Example.Setting' -Value 10 -Initialize -Validation 'integer' -Handler { } -Description "Example configuration setting. Your module can then use the setting using 'Get-PSFConfigValue'"
#>

Set-PSFConfig -Module 'PStSQLtTestGenerator' -Name 'Import.DoDotSource' -Value $false -Initialize -Validation 'bool' -Description "Whether the module files should be dotsourced on import. By default, the files of this module are read as string value and invoked, which is faster but worse on debugging."
Set-PSFConfig -Module 'PStSQLtTestGenerator' -Name 'Import.IndividualFiles' -Value $false -Initialize -Validation 'bool' -Description "Whether the module files should be imported individually. During the module build, all module code is compiled into few files, which are imported instead by default. Loading the compiled versions is faster, using the individual files is easier for debugging and testing out adjustments."

<#
# Example:
Register-PSFTeppScriptblock -Name "PStSQLtTestGenerator.alcohol" -ScriptBlock { 'Beer','Mead','Whiskey','Wine','Vodka','Rum (3y)', 'Rum (5y)', 'Rum (7y)' }
#>

<#
# Example:
Register-PSFTeppArgumentCompleter -Command Get-Alcohol -Parameter Type -Name PStSQLtTestGenerator.alcohol
#>

New-PSFLicense -Product 'PStSQLtTestGenerator' -Manufacturer 'sstad' -ProductVersion $script:ModuleVersion -ProductType Module -Name MIT -Version "1.0.0.0" -Date (Get-Date "2019-09-18") -Text @"
Copyright (c) 2019 sstad

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"@
#endregion Load compiled code