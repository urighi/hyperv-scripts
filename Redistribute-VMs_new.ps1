<#
.SYNOPSIS
Balances Hyper-V cluster nodes memory usage by moving virtual machines

.PARAMETER Percentage
The memory percentage difference (high and low) used to set the memory threshold.

.NOTES
Written by Ulisses Righi
ulisses@ulisoft.com.br
Version 1.0
5/4/2019

#>

[CmdletBinding()]
param(
	[Parameter( Mandatory=$false)]
    [double]$Percentage = 3
)

# Get memory information from nodes, sorts by FreePhysicalMemory (lowest free memory first)

$ClusterNodes = Get-WmiObject win32_operatingsystem -ComputerName (Get-ClusterNode | Where-Object {$_.State -eq "Up"}) | `
    Sort-Object -Property FreePhysicalMemory | Select-Object @{l='ComputerName';e={$_.__SERVER}}, `
    @{l='FreePhysicalMemory';e={$_.FreePhysicalMemory*1024}}

$VMMovePlans = New-Object System.Collections.ArrayList

# Calculates used memory average for all nodes

[double]$FreeMemoryAverage = 0
foreach ($Node in $ClusterNodes)
{
    $FreeMemoryAverage += $Node.FreePhysicalMemory
}

$FreeMemoryAverage = $FreeMemoryAverage / $ClusterNodes.Count

# Sets high threshold at used memory + percentage, low at used memory - percentage
$HighThreshold = $FreeMemoryAverage * (1 + $Percentage/100 )
$LowThreshold = $FreeMemoryAverage * (1 - $Percentage/100 )

Write-Host ("Low Threshold: {0:N2}GB" -f ($LowThreshold/1GB)) -ForegroundColor Yellow
Write-Host ("High Threshold: {0:N2}GB" -f ($HighThreshold/1GB)) -ForegroundColor Yellow
Write-Host ("Free Memory Average: {0:N2}GB" -f ($FreeMemoryAverage/1GB)) -ForegroundColor Yellow

# For each node, check if memory usage is above threshold. Then compiles a list of VMs by usage
foreach ($Node in $ClusterNodes)
{
    Write-Host "=========================================================="
    Write-Host ("Current node: $($Node.ComputerName)") -ForegroundColor Cyan
    Write-Host ("Free physical memory: {0:N2}GB" -f ($Node.FreePhysicalMemory/1GB))
    if ($Node.FreePhysicalMemory -lt $LowThreshold)
    {
        

        foreach ($DestinationNode in $ClusterNodes)
        {
            $NodeVMs = Get-VM -ComputerName $Node.ComputerName | Where-Object { ($_.State -eq "Running") -and `
                ((Get-VMReplication $_ -ErrorAction SilentlyContinue).State -ne "Resynchronizing") }
            if ($DestinationNode.ComputerName -ne $Node.ComputerName)
            {
                #Calculates delta for moving to other nodes in regards to average memory. Ensures the least amount of moves
                foreach ($VM in $NodeVMs)
                {

                    $SourceNodeFreeMemory = $Node.FreePhysicalMemory + $VM.MemoryAssigned
                    $DestinationNodeFreeMemory = ($DestinationNode.FreePhysicalMemory - $VM.MemoryAssigned)

                    if (($SourceNodeFreeMemory -lt $HighThreshold) -and ($DestinationNodeFreeMemory -gt $LowThreshold))
                    {
                        $Delta = [math]::Abs($Node.FreePhysicalMemory + $VM.MemoryAssigned - $FreeMemoryAverage) + `
                            [math]::Abs($DestinationNode.FreePhysicalMemory - $VM.MemoryAssigned - $FreeMemoryAverage)

                        $VMMovePlan = New-Object -TypeName PSObject
                        $VMMovePlan | Add-Member -MemberType NoteProperty -Name VMName $VM.Name
                        $VMMovePlan | Add-Member -MemberType NoteProperty -Name VMMemoryAssigned  $VM.MemoryAssigned
                        $VMMovePlan | Add-Member -MemberType NoteProperty -Name DestinationNode $DestinationNode.ComputerName
                        $VMMovePlan | Add-Member -MemberType NoteProperty -Name Source $Node.ComputerName
                        $VMMovePlan | Add-Member -MemberType NoteProperty -Name DestinationNodeFreeMemory $DestinationNodeFreeMemory
                        $VMMovePlan | Add-Member -MemberType NoteProperty -Name SourceNodeFreeMemory $SourceNodeFreeMemory
                        $VMMovePlan | Add-Member -MemberType NoteProperty -Name MemoryDelta $Delta

                        $VMMovePlans.Add($VMMovePlan) | Out-Null
                    }
                }
            }
        }

        while (($Node.FreePhysicalMemory -lt $LowThreshold) -and ($VMMovePlans.Count -gt 0))
        {
            $VMMovePlans = $VMMovePlans | Sort-Object MemoryDelta
            Write-Host "Top candidates:"
            $VMMovePlans | Select-Object VMName,DestinationNode,@{l="VMMemoryAssigned";e={"{0:N2}" -f ($_.VMMemoryAssigned/1GB)}},`
                @{l="MemoryDelta";e={"{0:N2}" -f ($_.MemoryDelta/1GB)}},`
                @{l="DestinationNodeFreeMemory";e={"{0:N2}" -f ($_.DestinationNodeFreeMemory/1GB)}},`
                @{l="SourceNodeFreeMemory";e={"{0:N2}" -f ($_.SourceNodeFreeMemory/1GB)}} -First 10 | Format-Table
			$DestinationNode = ($VMMovePlans[0].DestinationNode)
			$VMMemoryAssigned = ($VMMovePlans[0].VMMemoryAssigned)
            Write-Host "Considering move of $($VMMovePlans[0].VMName) from $($Node.ComputerName) to $DestinationNode..." -ForegroundColor Yellow
            Move-VM -Name $VMMovePlans[0].VMName -ComputerName $Node.ComputerName -DestinationHost $DestinationNode -Confirm
                       
			
			if ((Get-VM -Name $VMMovePlans[0].VMName -ComputerName $DestinationNode -ErrorAction SilentlyContinue))
			{
				$Node.FreePhysicalMemory += $VMMemoryAssigned
				
				# Updates memory usage on move plan
				foreach ($VMMovePlan in $VMMMovePlans)
				{
					if ($VMMovePlan.DestinationNode -eq $DestinationNode)
					{
						$VMMovePlan.DestinationNodeFreeMemory -= VMMemoryAssigned
					}
					
					$VMMovePlan.SourceNodeFreeMemory += $VMMemoryAssigned
					
                    $Delta = [math]::Abs($Node.FreePhysicalMemory + $VMMovePlan.VMMemoryAssigned - $FreeMemoryAverage) + `
                        [math]::Abs($VMMovePlan.DestinationNodeFreeMemory - $VMMovePlan.MemoryAssigned - $FreeMemoryAverage)
					$VMMovePlan.Delta = $Delta
				}
			}
			
			# Removes move plans for the recently moved or skipped VM
			$VMMovePlans = $VMMovePlans | Where-Object { $_.VMName -ne $VMMovePlans[0].VMName }
			
        }

    }
    else
    {
        Write-Host "Skipping node outside limits." -ForegroundColor Yellow
    }
}
