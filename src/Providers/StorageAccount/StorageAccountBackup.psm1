$script:AzCopyExePath = "C:\Program Files (x86)\Microsoft SDKs\Azure\AzCopy\AzCopy.exe"
$script:PagingSize = 250

function New-AzCopyCmd
{
  param(
    [Parameter(Mandatory)]
    [PSCustomObject]$SrcCtx,
    [Parameter(Mandatory)]
    [PSCustomObject]$DestCtx,
    [Parameter(Mandatory)]
    [string] $Source,
    [Parameter(Mandatory)]
    [string]$Dest,
    [string] $ExtraParams = "/y"
  )
  process {
    $srcStorageAccountKey = $SrcCtx.StorageAccount.Credentials.ExportBase64EncodedKey()
    $destStorageAccountKey = $DestCtx.StorageAccount.Credentials.ExportBase64EncodedKey()

    $cmd = @(
      ('"{0}"' -f $script:AzCopyExePath)
      ('/source:{0}' -f $Source)
      ('/dest:{0}' -f $Dest)
      ('/sourcekey:"{0}"' -f $srcStorageAccountKey)
      ('/destkey:"{0}"' -f $destStorageAccountKey)
      ('{0}' -f $ExtraParams)
    )

    $cmd -join ' '
  }
}

function Invoke-AzCopyCmd
{
  param(
    [Parameter(Mandatory)]
    [string]$AzCopyCmd
  )
  process {
    $result = cmd /c $AzCopyCmd
    foreach($s in $result)
    {
      Write-Host $s
    }

    if ($LASTEXITCODE -ne 0){
      Write-Error "Copy failed!";
      break;
    }
    else
    {
      Write-Host "Copy succeed!"
    }

    Write-Host "-----------------"
  }
}

function Backup-Blobs
{
  param(
    [Parameter(Mandatory)]
    [string]$DestinationPath,
    [Parameter(Mandatory)]
    [PSCustomObject]$SrcCtx,
    [Parameter(Mandatory)]
    [PSCustomObject]$DestCtx,
    [Parameter(Mandatory)]
    [array] $SrcStorageContainers
  )

  process {
    foreach ($srcStorageContainer in $SrcStorageContainers)
    {
      if($srcStorageContainer.Name -like '*$*')
      {
        Write-Host "-----------------"
        Write-Host "Skipping blob copy: $($srcStorageContainer.Name)"
        Write-Host "-----------------"
        Continue;
      }

      $source = $srcStorageContainer.CloudBlobContainer.Uri.AbsoluteUri
      $dest = '{0}{1}/blobs/{2}' -f $DestCtx.BlobEndPoint, $DestinationPath, $srcStorageContainer.Name

      Write-Host "-----------------"
      Write-Host "Blob copy:"
      Write-Host "  Source:       $($source)"
      Write-Host "  Destination:  $($dest)"
      Write-Host "-----------------"

      $azCopyCmd = New-AzCopyCmd -SrcCtx $SrcCtx -DestCtx $DestCtx -Source $source -Dest $dest -ExtraParams "/snapshot /y /s /synccopy"
      Invoke-AzCopyCmd -AzCopyCmd $AzCopyCmd
    }
  }
}

function Backup-Tables
{
  param(
    [Parameter(Mandatory)]
    [string]$DestinationPath,
    [Parameter(Mandatory)]
    [PSCustomObject]$SrcCtx,
    [Parameter(Mandatory)]
    [PSCustomObject]$DestCtx,
    [Parameter(Mandatory)]
    [array] $SrcStorageTables
  )
  process {
    foreach ($srcStorageTable in $SrcStorageTables)
    {
      $source = $srcStorageTable.CloudTable.Uri.AbsoluteUri
      $dest = "{0}{1}/tables/{2}" -f $DestCtx.BlobEndPoint, $DestinationPath, $srcStorageTable.Name

      Write-Host "-----------------"
      Write-Host "Table copy:"
      Write-Host "  Source:       $($source)"
      Write-Host "  Destination:  $($dest)"
      Write-Host "-----------------"

      $azCopyCmd = New-AzCopyCmd -SrcCtx $SrcCtx -DestCtx $DestCtx -Source $source -Dest $dest -ExtraParams "/y"
      Invoke-AzCopyCmd -AzCopyCmd $azCopyCmd
    }
  }
}

function Backup-StorageAccount
{
  param(
    [Parameter(Mandatory)]
    [PSCustomObject]$SrcCtx,
    [Parameter(Mandatory)]
    [PSCustomObject]$DestCtx
  )
  process {
    # Ensure blob container is created for backed up account
    $SrcStorageAccountName = $srcCtx.StorageAccount.Credentials.AccountName
    $destContainer = Get-AzStorageContainer -Name $SrcStorageAccountName -Context $destCtx -ErrorAction SilentlyContinue
    if ($null -eq $destContainer) {
      New-AzStorageContainer -Name $SrcStorageAccountName -Context $destCtx 
    }

    $currentDate = (Get-Date).ToUniversalTime().tostring('yyyy\/MM\/dd\/HH:mm')
    $destinationPath = $SrcStorageAccountName + "/" + $currentDate
    
    $srcTables = Get-AzStorageTable -Context $srcCtx
    if($srcTables)
    {
      Backup-Tables -DestinationPath $destinationPath -SrcCtx $SrcCtx -DestCtx $destCtx -SrcStorageTables $srcTables
    }
    
    $token = $null
    
    do {
      $srcContainers = Get-AzStorageContainer -MaxCount $script:PagingSize -ContinuationToken $token -Context $srcCtx
      
      if($srcContainers)
      {
        $token = $srcContainers[$srcContainers.Count -1].ContinuationToken;
        Backup-Blobs -DestinationPath $destinationPath -SrcCtx $SrcCtx -DestCtx $destCtx -SrcStorageContainers $srcContainers
      }
    } while ($null -ne $token)
  }
}

function Restore-Table
{
  param(
    [Parameter(Mandatory)]
    [string]$Source,
    [Parameter(Mandatory)]
    [string]$SourceManifest,
    [Parameter(Mandatory)]
    [string]$Dest,
    [Parameter(Mandatory)]
    [PSCustomObject]$SrcCtx,
    [Parameter(Mandatory)]
    [PSCustomObject]$DestCtx
  )

  process {
    Write-Host "-----------------"
    Write-Host "Table restore:"
    Write-Host "  Source:       $($Source)"
    Write-Host "  Destination:  $($Dest)"
    Write-Host "-----------------"

    $azCopyCmd = New-AzCopyCmd -SrcCtx $SrcCtx -DestCtx $DestCtx -Source $Source -Dest $Dest -ExtraParams $("/manifest:{0} /entityoperation:InsertOrReplace /y" -f $SourceManifest)
    
    Invoke-AzCopyCmd -AzCopyCmd $azCopyCmd
  }
}

function Restore-Blob
{
  param(
    [Parameter(Mandatory)]
    [string]$Source,
    [Parameter(Mandatory)]
    [string]$Dest,
    [Parameter(Mandatory)]
    [PSCustomObject]$SrcCtx,
    [Parameter(Mandatory)]
    [PSCustomObject]$DestCtx
  )

  process {
    Write-Host "-----------------"
    Write-Host "Blob restore:"
    Write-Host "  Source:       $($Source)"
    Write-Host "  Destination:  $($Dest)"
    Write-Host "-----------------"

    $azCopyCmd = New-AzCopyCmd -SrcCtx $SrcCtx -DestCtx $DestCtx -Source $Source -Dest $Dest -ExtraParams '/y /s /synccopy'
    
    Invoke-AzCopyCmd -AzCopyCmd $azCopyCmd
  }
}

function Get-TableRestoreContext {
  param(
    [Parameter(Mandatory)]
    [PSCustomObject]$SourceContext,
    [Parameter(Mandatory)]
    [PSCustomObject]$DestContext,
    [Parameter(Mandatory)]
    [string]$RestoredStorageAccountName,
    [Parameter(Mandatory)]
    [string]$RestoredBackupDate
  )
  begin {
    $originalPref = $ProgressPreference # Default is 'Continue'
    $ProgressPreference = "SilentlyContinue"
  }
  process {
    $token = $null
    $manifests = @()
    do {
      $manifests += Get-AzStorageBlob `
        -Container $RestoredStorageAccountName `
        -Context $SourceContext `
        -Blob $('{0}/tables/*manifest*' -f $RestoredBackupDate) `
        -MaxCount $script:PagingSize `
        -ContinuationToken $token

      if ($manifests) {
        $token = $manifests | Select-Object -Last 1 -ExpandProperty ContinuationToken
      } else {
        $token = $null
      }
    } while ($null -ne $token)

    $manifests | ForEach-Object {
      $tableName = $_.Name | `
        Select-String -Pattern '(?<=tables\/)(\w+)' | `
        Select-Object -ExpandProperty Matches | `
        Select-Object -ExpandProperty Value

      $sourceUrl = '{0}{1}/{2}/tables/{3}' -f $SourceContext.BlobEndPoint, $RestoredStorageAccountName, $RestoredBackupDate, $tableName
      $destUrl = '{0}{1}' -f $DestContext.TableEndPoint, $tableName

      [PSCustomObject]@{ 
        TableName = $tableName
        SourceManifest = Split-Path -Path $_.Name -Leaf
        SourceUrl = $sourceUrl
        DestUrl = $destUrl
      }
    }
  }
  end {
    $ProgressPreference = $originalPref
  }
}

function Get-BlobRestoreContext {
  param(
    [Parameter(Mandatory)]
    [PSCustomObject]$SourceContext,
    [Parameter(Mandatory)]
    [PSCustomObject]$DestContext,
    [Parameter(Mandatory)]
    [string]$RestoredStorageAccountName,
    [Parameter(Mandatory)]
    [string]$RestoredBackupDate
  )
  begin {
    $originalPref = $ProgressPreference # Default is 'Continue'
    $ProgressPreference = "SilentlyContinue"
  }
  process {
    $token = $null
    $blobs = @()
    do {
      $blobs += Get-AzStorageBlob `
        -Container $RestoredStorageAccountName `
        -Context $SourceContext `
        -Blob $('{0}/blobs/*' -f $RestoredBackupDate) `
        -MaxCount $script:PagingSize `
        -ContinuationToken $token

      if($blobs) {
        $token = $blobs | Select-Object -Last 1 -ExpandProperty ContinuationToken
      } else {
        $token = $null
      }
    } while ($null -ne $token)
    
    $uniqueBlobs = $blobs | `
      Select-Object -ExpandProperty Name | `
      Select-String -Pattern '(?<=\/blobs\/)([\w-_]+)' | `
      Select-Object -ExpandProperty Matches | `
      Select-Object -ExpandProperty Value | `
      Sort-Object -Unique

    $uniqueBlobs | ForEach-Object {
      $sourceUrl = '{0}{1}/{2}/blobs/{3}' -f $SourceContext.BlobEndPoint, $RestoredStorageAccountName, $RestoredBackupDate, $_
      $destUrl = '{0}{1}' -f $DestContext.BlobEndPoint, $_

      [PSCustomObject]@{ 
        SourceUrl = $sourceUrl
        DestUrl = $destUrl
      }
    }
  }
  end {
    $ProgressPreference = $originalPref
  }
}

function Restore-StorageAccount
{
  param(
    [Parameter(Mandatory)]
    [PSCustomObject]$SrcCtx,
    [Parameter(Mandatory)]
    [PSCustomObject]$DestCtx,
    [Parameter(Mandatory)]
    [string]$RestoredStorageAccountName,
    [Parameter(Mandatory)]
    [string]$RestoredBackupDate
  )
  process {
    Get-TableRestoreContext -SourceContext $SrcCtx -DestContext $DestCtx -RestoredStorageAccountName $RestoredStorageAccountName -RestoredBackupDate $RestoredBackupDate | ForEach-Object {
      Restore-Table -Source $_.SourceUrl -SourceManifest $_.SourceManifest -Dest $_.DestUrl -SrcCtx $SrcCtx -DestCtx $DestCtx
    }

    Get-BlobRestoreContext -SourceContext $SrcCtx -DestContext $DestCtx -RestoredStorageAccountName $RestoredStorageAccountName -RestoredBackupDate $RestoredBackupDate | ForEach-Object {
      Restore-Blob -Source $_.SourceUrl -Dest $_.DestUrl -SrcCtx $SrcCtx -DestCtx $DestCtx
    }
  }
}

function Get-StorageAccountContext
{
  param(
    [Parameter(Mandatory)]
    [string]$StorageAccountName,
    [Parameter(Mandatory)]
    [string]$StorageAccountResourceGroup
  )
  process {
    $storageAccountKey = (Get-AzStorageAccountKey -ResourceGroupName $StorageAccountResourceGroup -AccountName $StorageAccountName).Value[0]
    New-AzStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $storageAccountKey
  }
}

Export-ModuleMember -Function Get-StorageAccountContext
Export-ModuleMember -Function Backup-StorageAccount
Export-ModuleMember -Function Restore-StorageAccount