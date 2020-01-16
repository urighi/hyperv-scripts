<#
.SYNOPSIS
MergeVHDToParent.ps1 - Merges a virtual hard disk chain to the parent.

.PARAMETER VMName
The name of the VM with the VHDs to be merged.

.PARAMETER ComputerName
The name of the Hyper-V host.

.PARAMETER Confirm
Require confirmation before changing the VM disk path. Defaults to $true. Set to $false
for unattended merges.

.PARAMETER StartVMAfterCompletion
Start the VM after the VHDs are merged and the disk path is updated. Defaults to $false.
Set to $true for unattended merges.

.NOTES
Make sure you have proper backups before starting the merge operation.

Ulisses Righi
ulisses@ulisoft.com.br
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$VMName,
    [Parameter(Mandatory=$true)]
    [string]$ComputerName,
    [Parameter(Mandatory=$false)]
    [bool]$Confirm = $true,
    [Parameter(Mandatory=$false)]
    [bool]$StartVMAfterCompletion = $false
)

$script:LastParent = ""

function MergeRecursive ($path)
{
    if ($null -ne $path -or $path -ne "")
    {
        $VHD = Get-VHD $path
        $script:LastParent = $path
        if ($null -eq $VHD.ParentPath -or $VHD.ParentPath -ne "")
        {
            Write-Host "Merging:" -ForegroundColor Yellow
            Write-Host "$($VHD.Path) to" -ForegroundColor Cyan
            Write-Host $VHD.ParentPath -ForegroundColor Cyan
            try
            {
                Merge-VHD -Path $path -DestinationPath ($VHD.ParentPath)
                MergeRecursive $VHD.ParentPath
            }
            catch
            {
		        Write-Host $_.Exception.Message
            }
            
        }
    }
}

if ((Get-VM -VMName $VMName -ComputerName $ComputerName).State -ne "Off")
{
    Write-Error "Please make sure that the VM is not running before starting the merge operation."
}
else
{
    $VHDList = Get-VMHardDiskDrive -VMName $VMName -ComputerName $ComputerName

    foreach ($VHD in $VHDList)
    {
        MergeRecursive $VHD.Path
        Write-Host "Changing $($VHD.Path)" -ForegroundColor Cyan
        Write-Host "to $($script:LastParent)" -ForegroundColor Cyan
        Write-Host "on $VMName" -ForegroundColor Cyan
        
        $VHD | Set-VMHardDiskDrive -Path $script:LastParent -Confirm:$Confirm
    }

    if ($StartVMAfterCompletion) { Start-VM -Name $VMName -ComputerName $ComputerName  }
}