function Build-AzCopyCmd 
{
  param(
    [Parameter(Mandatory)] 
    [string]$DestinationPath,
    [Parameter(Mandatory)] 
    [PSCustomObject]$SrcCtx,
    [Parameter(Mandatory)] 
    [PSCustomObject]$DestCtx,
    [Parameter(Mandatory)] 
    [string] $AzCopyParam,
    [Parameter(Mandatory)] 
    [string] $SourcePath
  )

  $srcStorageAccountKey = $SrcCtx.StorageAccount.Credentials.ExportBase64EncodedKey()
  $destStorageAccountKey = $DestCtx.StorageAccount.Credentials.ExportBase64EncodedKey()
  $destContainer = $DestCtx.StorageAccount.CreateCloudBlobClient().GetContainerReference($DestinationPath) 
  return [string]::Format("""{0}"" /source:{1} /dest:{2} /sourcekey:""{3}"" /destkey:""{4}"" $AzCopyParam", "C:\Program Files (x86)\Microsoft SDKs\Azure\AzCopy\AzCopy.exe", $SourcePath, $destContainer.Uri.AbsoluteUri, $srcStorageAccountKey, $destStorageAccountKey)
}

function Invoke-AzCopyCmd 
{
  param(
    [Parameter(Mandatory)] 
    [string]$AzCopyCmd
  )

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
  
  Process {
    foreach ($srcStorageContainer in $SrcStorageContainers)
    {
      if($srcStorageContainer.Name -like '*$*')
      {
        Write-Host "-----------------"
        Write-Host "Skipping copy: $($srcStorageContainer.Name)"
        Write-Host "-----------------"
        Continue;
      }

      Write-Host "-----------------"
      Write-Host "Start copying: $($srcStorageContainer.Name)"
      Write-Host "-----------------"

      $blobDestinationPath = $DestinationPath + "/blobs/" + $srcStorageContainer.Name
      $azCopyParam = "/snapshot /y /s /synccopy"
      $sourcePath = $srcStorageContainer.CloudBlobContainer.Uri.AbsoluteUri
      $azCopyCmd = Build-AzCopyCmd -DestinationPath $blobDestinationPath -SrcCtx $SrcCtx -DestCtx $DestCtx -AzCopyParam $azCopyParam -SourcePath $sourcePath
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
  
  Process {
    foreach ($srcStorageTable in $SrcStorageTables)
    {
      Write-Host "-----------------"
      Write-Host "Start copying: $($srcStorageTable.Name)"
      Write-Host "-----------------"

      $tableDestinationPath = $DestinationPath + "/tables/" + $srcStorageTable.Name
      $azCopyParam = "/y"
      $sourcePath = $srcStorageTable.CloudTable.Uri.AbsoluteUri        
      $azCopyCmd = Build-AzCopyCmd -DestinationPath $tableDestinationPath -SrcCtx $SrcCtx -DestCtx $DestCtx -AzCopyParam $azCopyParam -SourcePath $sourcePath
      Invoke-AzCopyCmd -AzCopyCmd $AzCopyCmd
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

  $currentDate = (Get-Date).ToUniversalTime().tostring('yyyy\/MM\/dd\/HH:mm')
  $SrcStorageAccountName = $srcCtx.StorageAccount.Credentials.AccountName
  $destinationPath = $SrcStorageAccountName + "/" + $currentDate    

  $srcTables = Get-AzureStorageTable -Context $srcCtx
    
  if($srcTables)
  {
    Backup-Tables -DestinationPath $destinationPath -SrcCtx $SrcCtx -DestCtx $destCtx -SrcStorageTables $srcTables
  }

  $maxReturn = 250
  $token = $null

  do{      
    $srcContainers = Get-AzureStorageContainer -MaxCount $maxReturn -ContinuationToken $token -Context $srcCtx

    if($srcContainers)
    {
      $token = $srcContainers[$srcContainers.Count -1].ContinuationToken;
      Backup-Blobs -DestinationPath $destinationPath -SrcCtx $SrcCtx -DestCtx $destCtx -SrcStorageContainers $srcContainers
    }
  }
  While ($token -ne $null)
}

function Get-StorageAccountContext 
{
  param(
    [Parameter(Mandatory)] 
    [string]$StorageAccountName,
    [Parameter(Mandatory)] 
    [string]$StorageAccountResourceGroup
  )

  $storageAccountKey= (Get-AzureRmStorageAccountKey -ResourceGroupName $StorageAccountResourceGroup -AccountName $StorageAccountName).Value[0]
  return New-AzureStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $storageAccountKey
}

Export-ModuleMember -Function Get-StorageAccountContext
Export-ModuleMember -Function Backup-StorageAccount