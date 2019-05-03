Param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Appliance
)

$ErrorActionPreference = "Stop"

function Test-ForDotNetTool {
    if (-not (Test-Command "dotnet.exe")) {
        throw "This test tool requires the dotnet.exe command line tool"
    }
}

function Invoke-DotNetBuild {
    Param(
        [Parameter(Mandatory=$true, Position=0)]
        [string]$Directory
    )

    try
    {
        Push-Location $Directory
        & dotnet.exe build
    }
    finally
    {
        Pop-Location
    }
}

function Invoke-DotNetRun {
    Param(
        [Parameter(Mandatory=$true, Position=0)]
        [string]$Directory,
        [Parameter(Mandatory=$true, Position=1)]
        [string]$Password,
        [Parameter(Mandatory=$false, Position=2)]
        [string]$Command
    )

    try
    {
        Push-Location $Directory
        $local:Expression = "`"$Password`" | & dotnet.exe run -- $Command"
        Write-Host "Executing: $($local:Expression)"
        $local:Output = (Invoke-Expression $local:Expression)
        if ($local:Output -is [array])
        {
            # sometimes dotnet run adds weird debug output strings
            # we just want the string with the JSON in it
            $local:Output | ForEach-Object { 
                if ($_ -match "Error" -or $_ -match "Exception")
                {
                    throw $local:Output
                }
                try
                {
                    $local:Obj = (ConvertFrom-Json $_)
                }
                catch {}
            }
            if ($local:Obj)
            {
                $local:Obj
            }
        }
        elseif ($local:Output -match "Error" -or $local:Output -match "Exception")
        {
            throw $local:Output
        }
        elseif ($local:Output)
        {
            $local:Obj = (ConvertFrom-Json $local:Output)
            $local:Obj
        }
        # Crappy conditionals should have detected anything but empty output by here
    }
    finally
    {
        Pop-Location
    }
}

function Test-ReturnsSuccess {
    Param(
        [Parameter(Mandatory=$true, Position=0)]
        [string]$Directory,
        [Parameter(Mandatory=$true, Position=1)]
        [string]$Password,
        [Parameter(Mandatory=$false, Position=2)]
        [string]$Command
    )

    try
    {
        [bool](Invoke-DotNetRun $Directory $Password $Command)
    }
    catch
    {
        $false
    }
}

function Get-StringEscapedBody {
    Param(
        [Parameter(Mandatory=$true, Position=0)]
        [hashtable]$Body
    )

    # quoting with the Invoke-Expression is complicated
    # luckily our API will handle single quotes in JSON strings
    (ConvertTo-Json $Body -Compress).Replace("`"","'")
}

$script:ToolDir = (Resolve-Path "$PSScriptRoot\SafeguardDotNetTool")
$script:A2aToolDir = (Resolve-Path "$PSScriptRoot\SafeguardDotNetA2aTool")
$script:AccessRequestBrokerToolDir = (Resolve-Path "$PSScriptRoot\SafeguardDotNetAccessRequestBrokerTool")
$script:EventToolDir = (Resolve-Path "$PSScriptRoot\SafeguardDotNetEventTool")

$script:TestDataDir = (Resolve-Path "$PSScriptRoot\TestData")
$script:CertDir = (Resolve-Path "$($script:TestDataDir)\CERTS")

$script:Thumbprint = (Get-PfxCertificate "$($script:CertDir)\UserCert.cer").Thumbprint

Write-Host -ForegroundColor Yellow "Building projects..."
Test-ForDotNetTool
Invoke-DotNetBuild $script:ToolDir
Invoke-DotNetBuild $script:A2aToolDir
Invoke-DotNetBuild $script:AccessRequestBrokerToolDir
Invoke-DotNetBuild $script:EventToolDir

Write-Host -ForegroundColor Yellow "Testing whether can connect to Safeguard ($Appliance) as bootstrap admin..."
Invoke-DotNetRun $script:ToolDir "Admin123" "-a $Appliance -u Admin -x -s Core -m Get -U Me -p"

Write-Host -ForegroundColor Yellow "Setting up a test user (SafeguardDotNetTest)..."
if (-not (Test-ReturnsSuccess $script:ToolDir "Admin123" "-a 10.5.32.162 -u Admin -x -s Core -m Get -U `"Users?filter=UserName%20eq%20'SafeguardDotNetTest'`" -p"))
{
    $local:Body = @{
        PrimaryAuthenticationProviderId = -1;
        UserName = "SafeguardDotNetTest";
        AdminRoles = @('GlobalAdmin','Auditor','AssetAdmin','ApplianceAdmin','PolicyAdmin','UserAdmin','HelpdeskAdmin','OperationsAdmin')
    }
    $local:Result = (Invoke-DotNetRun $script:ToolDir "Admin123" "-a 10.5.32.162 -u Admin -x -s Core -m Post -U Users -p -b `"$(Get-StringEscapedBody $local:Body)`"")
    $local:Result
    Invoke-DotNetRun $script:ToolDir "Admin123" "-a 10.5.32.162 -u Admin -x -s Core -m Put -U Users/$($local:Result.Id)/Password -p -b `"'Test123'`""
}
else
{
    Write-Host "'SafeguardDotNetTest' user already exists"
}

Write-Host -ForegroundColor Yellow "Setting up a cert user (SafeguardDotNetCert)..."
if (-not (Test-ReturnsSuccess $script:ToolDir "Test123" "-a 10.5.32.162 -u SafeguardDotNetTest -x -s Core -m Get -U `"Users?filter=UserName%20eq%20'SafeguardDotNetCert'`" -p"))
{
    $local:Body = @{
        PrimaryAuthenticationProviderId = -2;
        UserName = "SafeguardDotNetCert";
        PrimaryAuthenticationIdentity = $script:Thumbprint
    }
    Invoke-DotNetRun $script:ToolDir "Test123" "-a 10.5.32.162 -u SafeguardDotNetTest -x -s Core -m Post -U Users -p -b `"$(Get-StringEscapedBody $local:Body)`""
}
else
{
    Write-Host "'SafeguardDotNetCert' user already exists"
}