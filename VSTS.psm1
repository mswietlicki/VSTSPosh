
<#
    .SYNOPSIS
        Generates a VSTS session object.
#>
function New-VstsSession {
    [CmdletBinding(DefaultParameterSetName="Account")]
    [OutputType([PSCustomObject])]
    param(
        #Name of the [AccountName].visualstudio.com
        [Parameter(Mandatory, ParameterSetName = 'Account')] $AccountName,
        [Parameter(Mandatory)] $User,
        [Parameter(Mandatory)] $Token,
        [Parameter()][string] $Collection = 'DefaultCollection',
        [Parameter(Mandatory, ParameterSetName = 'Server')][string] $Server = 'visualstudio.com',
        [Parameter()][ValidateSet('HTTP','HTTPS')] $Scheme = 'HTTPS'
    )

    [PSCustomObject]@{
        AccountName = $AccountName
        User = $User
        Token = $Token
        Collection = $Collection
        Server = $Server
        Scheme = $Scheme
    }
}

<#
    .SYNOPSIS
        Generates and invokes rest query on VSTS.
#>
function Invoke-VstsEndpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter()][hashtable] $QueryStringParameters,
        [Parameter()][string] $Project,
        [Parameter()][uri] $Path,
        [Parameter()][string] $ApiVersion = '1.0',
        [Parameter()][ValidateSet('GET','PUT','POST','DELETE','PATCH')] $Method = 'GET',
        [Parameter()][string] $Body,
        [Parameter()][string] $OutFile
    )

    $queryString = [System.Web.HttpUtility]::ParseQueryString([string]::Empty)

    if ($QueryStringParameters -ne $null)
    {
        foreach ($parameter in $QueryStringParameters.GetEnumerator())
        {
            $queryString[$parameter.Key] = $parameter.Value
        }
    }

    $queryString["api-version"] = $ApiVersion
    $queryString = $queryString.ToString();

    $authorization = Get-VstsAuthorization -User $Session.User -Token $Session.Token
    if ([string]::IsNullOrEmpty($Session.AccountName))
    {
        $UriBuilder = New-Object System.UriBuilder -ArgumentList "$($Session.Scheme)://$($Session.Server)"
    }
    else
    {
        $UriBuilder = New-Object System.UriBuilder -ArgumentList "$($Session.Scheme)://$($Session.AccountName).visualstudio.com"
    }
    $Collection = $Session.Collection

    $UriBuilder.Query = $queryString
    if ([string]::IsNullOrEmpty($Project))
    {
        $UriBuilder.Path = "$Collection/_apis/$Path"
    }
    else
    {
        $UriBuilder.Path = "$Collection/$Project/_apis/$Path"
    }

    $Uri = $UriBuilder.Uri

    Write-Verbose "Invoke URI [$uri]"

    $ContentType = 'application/json'
    if ($Method -eq 'PUT' -or $Method -eq 'POST' -or $Method -eq 'PATCH')
    {
        if ($Method -eq 'PATCH')
        {
            $ContentType = 'application/json-patch+json'
        }

        Invoke-RestMethod $Uri -Method $Method -ContentType $ContentType -Headers @{ Authorization = $authorization } -Body $Body
    }
    elseif ($OutFile -ne $null)
    {
        Invoke-RestMethod $Uri -Method $Method -ContentType $ContentType -Headers @{ Authorization = $authorization } -OutFile $OutFile
    }
    else
    {
        Invoke-RestMethod $Uri -Method $Method -ContentType $ContentType -Headers @{ Authorization = $authorization }
    }
}

<#
    .SYNOPSIS
        Generates a VSTS authorization header value from a username and Personal Access Token.
#>
function Get-VstsAuthorization {
    [CmdletBinding()]
    param(
        [Parameter()][string] $User,
        [Parameter()][string] $Token
    )

    $Value = [convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $User,$Token)))
    ("Basic {0}" -f $value)
}

<#
    .SYNOPSIS
        Get projects in a VSTS account.
#>
function Get-VstsProject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,ParameterSetName = 'Account')] $AccountName,
        [Parameter(Mandatory,ParameterSetName = 'Account')] $User,
        [Parameter(Mandatory,ParameterSetName = 'Account')] $Token,
        [Parameter(Mandatory,ParameterSetName = 'Session')] $Session,
        [Parameter()][string] $Name)

    if ($PSCmdlet.ParameterSetName -eq 'Account')
    {
        $Session = New-VstsSession -AccountName $AccountName -User $User -Token $Token
    }

    $Value = Invoke-VstsEndpoint -Session $Session -Path 'projects'

    if ($PSBoundParameters.ContainsKey("Name"))
    {
        $Value.Value | Where Name -EQ $Name
    }
    else
    {
        $Value.Value
    }
}


function Wait-VSTSProject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory)] $Name,
        [Parameter()] $Attempts = 30,
        [Parameter()][switch] $Exists)

    $Retries = 0
    do {
        #Takes a few seconds for the project to be created
        Start-Sleep -Seconds 2

        $TeamProject = Get-VstsProject -Session $Session -Name $Name

        $Retries++
    } while ((($TeamProject -eq $null -and $Exists) -or ($TeamProject -ne $null -and -not $Exists)) -and $Retries -le $Attempts)

    if (($TeamProject -eq $null -and $Exists) -or ($TeamProject -ne $null -and -not $Exists))
    {
        throw "Failed to create team project!"
    }
}

<#
    .SYNOPSIS
        Creates a new project in a VSTS account
#>
function New-VstsProject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,ParameterSetName = 'Account')] $AccountName,
        [Parameter(Mandatory,ParameterSetName = 'Account')] $User,
        [Parameter(Mandatory,ParameterSetName = 'Account')] $Token,
        [Parameter(Mandatory,ParameterSetName = 'Session')] $Session,
        [Parameter(Mandatory)] $Name,
        [Parameter()] $Description,
        [Parameter()][ValidateSet('Git')] $SourceControlType = 'Git',
        [Parameter()] $TemplateTypeId = '6b724908-ef14-45cf-84f8-768b5384da45',
        [Parameter()] $TemplateTypeName = 'Agile',
        [Parameter()][switch] $Wait)

    if ($PSCmdlet.ParameterSetName -eq 'Account')
    {
        $Session = New-VstsSession -AccountName $AccountName -User $User -Token $Token
    }

    if ($PSBoundParameters.ContainsKey('TemplateTypeName'))
    {
        $TemplateTypeId = Get-VstsProcess -Session $Session | Where Name -EQ $TemplateTypeName | Select -ExpandProperty Id
        if ($TemplateTypeId -eq $null)
        {
            throw "Template $TemplateTypeName not found."
        }
    }

    $Body = @{
        name = $Name
        description = $Description
        capabilities = @{
            versioncontrol = @{
                sourceControlType = $SourceControlType
            }
            processTemplate = @{
                templateTypeId = $TemplateTypeId
            }
        }
    } | ConvertTo-Json

    Invoke-VstsEndpoint -Session $Session -Path 'projects' -Method POST -Body $Body

    if ($Wait)
    {
        Wait-VSTSProject -Session $Session -Name $Name -Exists
    }
}

<#
    .SYNOPSIS
        Deletes a project from the specified VSTS account.
#>
function Remove-VstsProject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,ParameterSetName = 'Account')] $AccountName,
        [Parameter(Mandatory,ParameterSetName = 'Account')] $User,
        [Parameter(Mandatory,ParameterSetName = 'Account')] $Token,
        [Parameter(Mandatory,ParameterSetName = 'Session')] $Session,
        [Parameter(Mandatory)] $Name,
        [Parameter()][switch] $Wait)

    if ($PSCmdlet.ParameterSetName -eq 'Account')
    {
        $Session = New-VstsSession -AccountName $AccountName -User $User -Token $Token
    }

    $Id = Get-VstsProject -Session $Session -Name $Name | Select -ExpandProperty Id

    if ($Id -eq $null)
    {
        throw "Project $Name not found in $AccountName."
    }

    Invoke-VstsEndpoint -Session $Session -Path "projects/$Id" -Method DELETE

    if ($Wait)
    {
        Wait-VSTSProject -Session $Session -Name $Name
    }
}

<#
    .SYNOPSIS
        Get work items from VSTS
#>
function Get-VstsWorkItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,ParameterSetName = 'Account')] $AccountName,
        [Parameter(Mandatory,ParameterSetName = 'Account')] $User,
        [Parameter(Mandatory,ParameterSetName = 'Account')] $Token,
        [Parameter(Mandatory,ParameterSetName = 'Session')] $Session,
        [Parameter(Mandatory)] $Id)

    if ($PSCmdlet.ParameterSetName -eq 'Account')
    {
        $Session = New-VstsSession -AccountName $AccountName -User $User -Token $Token
    }

    Invoke-VstsEndpoint -Session $Session -Path 'wit/workitems' -QueryStringParameters @{ ids = $id }
}

<#
    .SYNOPSIS
        Create new work items in VSTS
#>
function New-VstsWorkItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,ParameterSetName = 'Account')] $AccountName,
        [Parameter(Mandatory,ParameterSetName = 'Account')] $User,
        [Parameter(Mandatory,ParameterSetName = 'Account')] $Token,
        [Parameter(Mandatory,ParameterSetName = 'Session')] $Session,
        [Parameter(Mandatory)] $Project,
        [Parameter()][hashtable] $PropertyHashtable,
        [Parameter(Mandatory)][string] $WorkItemType
    )

    if ($PSCmdlet.ParameterSetName -eq 'Account')
    {
        $Session = New-VstsSession -AccountName $AccountName -User $User -Token $Token
    }

    if ($PropertyHashtable -ne $null)
    {
        $Fields = foreach ($kvp in $PropertyHashtable.GetEnumerator())
        {
            [PSCustomObject]@{
                op = 'add'
                Path = '/fields/' + $kvp.Key
                Value = $kvp.Value
            }
        }

        $Body = $Fields | ConvertTo-Json
    }
    else
    {
        $Body = [string]::Empty
    }

    Invoke-VstsEndpoint -Session $Session -Path "wit/workitems/`$$($WorkItemType)" -Method PATCH -Project $Project -Body $Body
}

<#
    .SYNOPSIS
        Returns a list of work item queries from the specified folder.
#>
function Get-VstsWorkItemQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,ParameterSetName = 'Account')] $AccountName,
        [Parameter(Mandatory,ParameterSetName = 'Account')] $User,
        [Parameter(Mandatory,ParameterSetName = 'Account')] $Token,
        [Parameter(Mandatory,ParameterSetName = 'Session')] $Session,
        [Parameter(Mandatory)] $Project,
        [Parameter()] $FolderPath
    )

    if ($PSCmdlet.ParameterSetName -eq 'Account')
    {
        $Session = New-VstsSession -AccountName $AccountName -User $User -Token $Token
    }

    $Result = Invoke-VstsEndpoint -Session $Session -Project $Project -Path 'wit/queries' -QueryStringParameters @{ depth = 1 }

    foreach ($value in $Result.Value)
    {
        if ($Value.isFolder -and $Value.hasChildren)
        {
            Write-Verbose "$Value.Name"
            foreach ($child in $value.Children)
            {
                if (-not $child.isFolder)
                {
                    $child
                }
            }
        }
    }
}

<#
    .SYNOPSIS
        Creates a new Git repository in the specified team project.
#>
function New-VstsGitRepository {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,ParameterSetName = 'Account')] $AccountName,
        [Parameter(Mandatory,ParameterSetName = 'Account')] $User,
        [Parameter(Mandatory,ParameterSetName = 'Account')] $Token,
        [Parameter(Mandatory,ParameterSetName = 'Session')] $Session,
        [Parameter(Mandatory)] $Project,
        [Parameter(Mandatory)] $RepositoryName
    )

    if ($PSCmdlet.ParameterSetName -eq 'Account')
    {
        $Session = New-VstsSession -AccountName $AccountName -User $User -Token $Token
    }

    if (-not (Test-Guid $Project))
    {
        $Project = Get-VstsProject -Session $Session -Name $Project | Select -ExpandProperty Id
    }

    $Body = @{
        name = $RepositoryName
        Project = @{
            Id = $Project
        }
    } | ConvertTo-Json

    Invoke-VstsEndpoint -Session $Session -Method POST -Path 'git/repositories' -Body $Body
}

<#
    .SYNOPSIS
        Gets Git repositories in the specified team project.
#>
function Get-VstsGitRepository {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,ParameterSetName = 'Account')] $AccountName,
        [Parameter(Mandatory,ParameterSetName = 'Account')] $User,
        [Parameter(Mandatory,ParameterSetName = 'Account')] $Token,
        [Parameter(Mandatory,ParameterSetName = 'Session')] $Session,
        [Parameter(Mandatory)] $Project
    )

    if ($PSCmdlet.ParameterSetName -eq 'Account')
    {
        $Session = New-VstsSession -AccountName $AccountName -User $User -Token $Token
    }

    $Result = Invoke-VstsEndpoint -Session $Session -Project $Project -Path 'git/repositories' -QueryStringParameters @{ depth = 1 }
    $Result.Value
}

<#
    .SYNOPSIS
        Get code policies for the specified project.
#>
function Get-VstsCodePolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,ParameterSetName = 'Account')] $AccountName,
        [Parameter(Mandatory,ParameterSetName = 'Account')] $User,
        [Parameter(Mandatory,ParameterSetName = 'Account')] $Token,
        [Parameter(Mandatory,ParameterSetName = 'Session')] $Session,
        [Parameter(Mandatory)] $Project
    )

    if ($PSCmdlet.ParameterSetName -eq 'Account')
    {
        $Session = New-VstsSession -AccountName $AccountName -User $User -Token $Token
    }

    $Result = Invoke-VstsEndpoint -Session $Session -Project $Project -Path 'policy/configurations' -ApiVersion '2.0-preview.1'
    $Result.Value
}

<#
    .SYNOPSIS
        Creates a new Code Policy configuration for the specified project.
#>
function New-VstsCodePolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,ParameterSetName = 'Account')] $AccountName,
        [Parameter(Mandatory,ParameterSetName = 'Account')] $User,
        [Parameter(Mandatory,ParameterSetName = 'Account')] $Token,
        [Parameter(Mandatory,ParameterSetName = 'Session')] $Session,
        [Parameter(Mandatory)] $Project,
        [Parameter()][guid] $RepositoryId = [guid]::Empty,
        [Parameter()][int] $MinimumReviewers,
        [Parameter()][string[]] $Branches
    )

    $RepoId = $null
    if ($RepositoryId -ne [guid]::Empty)
    {
        $RepoId = $RepositoryId.ToString()
    }

    $scopes = foreach ($branch in $Branches)
    {
        @{
            repositoryId = $RepoId
            refName = "refs/heads/$branch"
            matchKind = "exact"
        }
    }

    $Policy = @{
        isEnabled = $true
        isBlocking = $false
        type = @{
            Id = 'fa4e907d-c16b-4a4c-9dfa-4906e5d171dd'
        }
        settings = @{
            minimumApproverCount = $MinimumReviewers
            creatorVoteCounts = $false
            scope = @( $scopes)
        }
    } | ConvertTo-Json -Depth 10

    if ($PSCmdlet.ParameterSetName -eq 'Account')
    {
        $Session = New-VstsSession -AccountName $AccountName -User $User -Token $Token
    }

    Invoke-VstsEndpoint -Session $Session -Project $Project -ApiVersion '2.0-preview.1' -Body $Policy -Method POST
}

<#
    .SYNOPSIS
        Gets team project processes.
#>
function Get-VstsProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Session
    )

    $Result = Invoke-VstsEndpoint -Session $Session -Path 'process/processes'
    $Result.Value
}

<#
    .SYNOPSIS
        Gets team project builds.
#>
function Get-VstsBuild {
    [CmdletBinding(DefaultParameterSetName="Query")]
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory)] $Project,
        [Parameter(Mandatory, ParameterSetName = 'Id')]
        [int] $Id,

        [Parameter(ParameterSetName = 'Query')]
        $DefinitionId,

        [Parameter(ParameterSetName = 'Query')]
        [ValidateSet('inProgress','completed','cancelling','postponed','notStarted','all')]
        $StatusFilter,

        [Parameter(ParameterSetName = 'Query')]
        [ValidateSet('succeeded','partiallySucceeded','failed','canceled')]
        $ResultFilter,

        [Parameter(ParameterSetName = 'Query')]
        $Top
    )

    if ($PSCmdlet.ParameterSetName -eq 'Id'){
        $path = "build/builds/$Id"
        $queryParameters = $null
    } else {
        $path = "build/builds"
        $queryParameters = @{ }
        if($DefinitionId -ne $null){
            $queryParameters["definitions"] = $DefinitionId
        }
        if($StatusFilter -ne $null){
            $queryParameters["statusFilter"] = $StatusFilter
        }
        if($ResultFilter -ne $null){
            $queryParameters["resultFilter"] = $ResultFilter
        }
        if($Top -ne $null){
            $queryParameters['$top'] = $Top
        }
    }

    $Result = Invoke-VstsEndpoint -Session $Session -Path $path -QueryStringParameters $queryParameters -Project $Project -ApiVersion '2.0'
    if($PSCmdlet.ParameterSetName -eq 'Id'){
        $Result
    }
    else {
        $Result.Value
    }
}

<#
    .SYNOPSIS
        Gets team project build artifacts.
#>
function Get-VstsBuildArtifacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory)] $Project,
        [Parameter(Mandatory)][int] $BuildId
    )

    $Result = Invoke-VstsEndpoint -Session $Session -Path "build/builds/$BuildId/artifacts" -Project $Project -ApiVersion '2.0'
    $Result.Value
}

<#
    .SYNOPSIS
        Downloads team project build artifact zipped content.
#>
function Get-VstsBuildArtifactFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory)] $Project,
        [Parameter(Mandatory)][int] $BuildId,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $OutFile
    )

    Invoke-VstsEndpoint -Session $Session -Path "build/builds/$BuildId/artifacts/$Name" -QueryStringParameters @{ '$format' = "zip" } -Project $Project -ApiVersion '2.0' -OutFile $OutFile
}

<#
    .SYNOPSIS
        Gets team project build definitions.
#>
function Get-VstsBuildDefinition {
    [CmdletBinding(DefaultParameterSetName="All")]
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory)] $Project,
        [Parameter(Mandatory, ParameterSetName = 'Id')][int] $Id,
        [Parameter(Mandatory, ParameterSetName = 'Name')][string] $Name
    )

    $queryParameters = $null
    if ($PSCmdlet.ParameterSetName -eq 'Id')
    {
        $path = "build/definitions/$Id"
    }
    elseif ($PSCmdlet.ParameterSetName -eq 'Name')
    {
        $path = 'build/definitions'
        $queryParameters = @{ name = $Name }
    }
    else
    {
        $path = 'build/definitions'
    }

    $Result = Invoke-VstsEndpoint -Session $Session -Path $path -QueryStringParameters $queryParameters -Project $Project -ApiVersion '2.0'

    if($PSCmdlet.ParameterSetName -eq 'Id')
    {
        $Result
    }
    elseif($PSCmdlet.ParameterSetName -eq 'Name')
    {
        $Result.Value[0]
    }
    else
    {
        $Result.Value
    }
}

<#
    .SYNOPSIS
        Validate Guid.
#>
function Test-Guid {
    [CmdletBinding()]
    [OutputType([Boolean])]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)] $Input
    )
    Process {
        $Guid = [guid]::Empty
        [guid]::TryParse($Input,[ref]$Guid)
    }
}

<#
    .SYNOPSIS
        Gets build definitions for the specified project.
#>
function New-VstsBuildDefinition {
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory)] $Project,
        [Parameter(Mandatory)] $Name,
        [Parameter()] $DisplayName = $Name,
        [Parameter()] $Comment,
        [Parameter(Mandatory)] $Queue,
        [Parameter(Mandatory)][PSCustomObject] $Repository
    )

    if (-not (Test-Guid -Input $Queue))
    {
        $Queue = Get-VstsBuildQueue -Session $Session | Where Name -EQ $Queue | Select -ExpandProperty Id
    }

    $Body = @{
        name = $Name
        type = "build"
        quality = "definition"
        queue = @{
            Id = $Queue
        }
        build = @(
            @{
                enabled = $true
                continueOnError = $false
                alwaysRun = $false
                displayName = $DisplayName
                task = @{
                    Id = "71a9a2d3-a98a-4caa-96ab-affca411ecda"
                    versionSpec = "*"
                }
                inputs = @{
                    "solution" = "**\\*.sln"
                    "msbuildArgs" = ""
                    "platform" = '$(platform)'
                    "configuration" = '$(config)'
                    "clean" = "false"
                    "restoreNugetPackages" = "true"
                    "vsLocationMethod" = "version"
                    "vsVersion" = "latest"
                    "vsLocation" = ""
                    "msbuildLocationMethod" = "version"
                    "msbuildVersion" = "latest"
                    "msbuildArchitecture" = "x86"
                    "msbuildLocation" = ""
                    "logProjectEvents" = "true"
                }
            },
            @{
                "enabled" = $true
                "continueOnError" = $false
                "alwaysRun" = $false
                "displayName" = "Test Assemblies **\\*test*.dll;-:**\\obj\\**"
                "task" = @{
                    "id" = "ef087383-ee5e-42c7-9a53-ab56c98420f9"
                    "versionSpec" = "*"
                }
                "inputs" = @{
                    "testAssembly" = "**\\*test*.dll;-:**\\obj\\**"
                    "testFiltercriteria" = ""
                    "runSettingsFile" = ""
                    "codeCoverageEnabled" = "true"
                    "otherConsoleOptions" = ""
                    "vsTestVersion" = "14.0"
                    "pathtoCustomTestAdapters" = ""
                }
            }
        )
        "repository" = @{
            "id" = $Repository.Id
            "type" = "tfsgit"
            "name" = $Repository.name
            "localPath" = "`$(sys.sourceFolder)/$($Repository.Name)"
            "defaultBranch" = "refs/heads/master"
            "url" = $Repository.Url
            "clean" = "false"
        }
        "options" = @(
            @{
                "enabled" = $true
                "definition" = @{
                    "id" = "7c555368-ca64-4199-add6-9ebaf0b0137d"
                }
                "inputs" = @{
                    "parallel" = "false"
                    "multipliers" = @( "config","platform")
                }
            }
        )
        "variables" = @{
            "forceClean" = @{
                "value" = "false"
                "allowOverride" = $true
            }
            "config" = @{
                "value" = "debug, release"
                "allowOverride" = $true
            }
            "platform" = @{
                "value" = "any cpu"
                "allowOverride" = $true
            }
        }
        "triggers" = @()
        "comment" = $Comment
    } | ConvertTo-Json -Depth 20

    Invoke-VstsEndpoint -Session $Session -Path 'build/definitions' -ApiVersion 2.0 -Method POST -Body $Body -Project $Project
}

<#
    .SYNOPSIS
        Gets build definitions for the collection.
#>
function Get-VstsBuildQueue {
    param(
        [Parameter(Mandatory)] $Session
    )

    $Result = Invoke-VstsEndpoint -Session $Session -Path 'build/queues' -ApiVersion 2.0
    $Result.Value
}

<#
    .SYNOPSIS
        Converts a TFVC repository to a VSTS Git repository.
#>
function ConvertTo-VstsGitRepository {
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory)] $TargetName,
        [Parameter(Mandatory)] $SourceFolder,
        [Parameter(Mandatory)] $ProjectName
    )

    $GitCommand = Get-Command git
    if ($GitCommand -eq $null -or $GitCommand.CommandType -ne 'Application' -or $GitCommand.name -ne 'git.exe')
    {
        throw "Git-tfs needs to be installed to use this command. See https://github.com/git-tfs/git-tfs. You can install with Chocolatey: cinst gittfs"
    }

    $GitTfsCommand = Get-Command git-tfs
    if ($GitTfsCommand -eq $null -or $GitTfsCommand.CommandType -ne 'Application' -or $GitTfsCommand.name -ne 'git-tfs.exe')
    {
        throw "Git-tfs needs to be installed to use this command. See https://github.com/git-tfs/git-tfs. You can install with Chocolatey: cinst gittfs"
    }

    git tfs clone "https://$($Session.AccountName).visualstudio.com/defaultcollection" "$/$ProjectName/$SourceFolder" --branches=none

    Push-Location (Split-Path $SourceFolder -Leaf)

    New-VstsGitRepository -Session $Session -RepositoryName $TargetName -Project $ProjectName | Out-Null

    git checkout -b develop
    git remote add origin https://$($Session.AccountName).visualstudio.com/DefaultCollection/$ProjectName/_git/$TargetName
    git push --all origin
    git tfs cleanup

    Pop-Location
    Remove-Item (Split-Path $SourceFolder -Leaf) -Force
}