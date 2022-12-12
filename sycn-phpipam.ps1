#Install-Module psphpipam -Confirm:$False -Force
Import-Module psphpipam
Import-Module DHCPServer
#only use when running with Azure Automate
#Import-Module Orchestrator.AssetManagement.Cmdlets

#return cidr value based on the dotted value
function Get-Mask {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]    
        [string]$Mask
    )
    Begin {
        $masks = @{ '255.255.255.255' = 32; '255.255.255.252' = 30; '255.255.255.248' = 29; '255.255.255.240' = 28; '255.255.255.224' = 27 ; '255.255.255.192' = 26; '255.255.255.128' = 25; '255.255.255.0' = 24; '255.255.254.0' = 23;	'255.255.252.0' = 22; '255.255.248.0' = 21;	'255.255.240.0' = 20; '255.255.224.0' = 19; '255.255.192.0' = 18; '255.255.128.0' = 17;	'255.255.0.0' = 16; '255.254.0.0' = 15;	'255.252.0.0' = 14; '255.248.0.0' = 13; '255.240.0.0' = 12; '255.224.0.0' = 11;	'255.192.0.0' = 10; '255.128.0.0' = 9;	'255.0.0.0' = 8 }
    }
    Process {
        return $masks.$Mask
    }    
}

function IsIPinRange {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]    
        [string]$StartRange,
        [Parameter(Mandatory)]    
        [string]$EndRange,
        [Parameter(Mandatory)]    
        [string]$IpToCheck
    )
    Begin {
        $rangeFrom = $StartRange
        $rangeTo = $EndRange
        $ip = $IpToCheck
    }
    Process {
        #https://www.reddit.com/r/PowerShell/comments/bcawvd/comment/ekpbbo0/?utm_source=share&utm_medium=web2x&context=3
        return ([version]$rangeFrom) -le ([version]$ip) -and ([version]$ip) -le ([version]$rangeTo)
    }
    
}

function Update-IPAM {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]    
        [System.Object]$DhcpList,
        [Parameter(Mandatory)]    
        [string]$IpamSubnetId
    )
    Begin {
    }
    Process {
        foreach ($address in $DhcpList) {
            #get the PHPIPAM object
            $ipamAddress = Get-PhpIpamAddress -IP $address.IPAddress #when no IP is found in IPAM they variable will be empty
            if ($ipamAddress) {
                #update the PHPIPAM object with the correct info from the DHCP server
                if ($ipamAddress.hostname -ne $address.HostName) {
                    Update-PhpIpamAddress -params @{id = $ipamAddress.id; hostname = $address.HostName; note = "This was synced with an automation script on $(Get-Date -Format "dd/MM/yyyy HH:mm")" }
                }
            }
            else {
                #create a new address in IPAM when it doesn't exists
                New-PhpIpamAddress -params @{subnetId = $IpamSubnetId; ip = $address.IPAddress; hostname = $address.HostName; note = "This was synced with an automation script on $(Get-Date -Format "dd/MM/yyyy HH:mm")" }
            }
        }
    }
    
}

#connect to IPAM
New-PhpIpamSession -UseStaticAppKeyAuth -PhpIpamApiUrl https://phpipam.example.com/api -AppID 'sync-app' -AppKey 'get the key in IPAM'

$servers = 'dhcp1.example.com', 'dhcp2.example.com', 'dhcp3.example.com'

foreach ($server in $servers) {
    $scopes = Get-DhcpServerv4Scope -ComputerName $server
    #get all scopeId from the DHCP server
    foreach ($scope in $scopes) {
        #get all leases from a scope
        $leases = Get-DhcpServerv4Lease -ScopeId $scope.ScopeId -ComputerName $server
        $exclusions = Get-DhcpServerv4ExclusionRange -ScopeId $scope.ScopeId -ComputerName $server
        $reservations = Get-DhcpServerv4Reservation  -ScopeId $scope.ScopeId -ComputerName $server
        #get all IP's in IPAM for that specific scope
        $ipamSubnetObject = get-PhpIpamSubnetByCIDR "$($scope.ScopeId)/$(Get-Mask -Mask $scope.SubnetMask)"
        $ipamScopeList = $ipamSubnetObject | ForEach-Object { Get-PhpIpamSubnetAddressesByID -ID $_.id }        

        #remove IP's from IPAM
        foreach ($ip in $ipamScopeList) {
            $remove = $false
            #is IP in the range for distribution by DHCP
            if (IsIPinRange -StartRange $scope.StartRange.IPAddressToString -EndRange $scope.EndRange.IPAddressToString -IpToCheck $ip.ip) {
                #iterate over all exclusions ranges
                if ($exclusions) {
                    $exclusionFound = $false
                    #determine if the IP is in the range of exclusions
                    foreach ($exclusion in $exclusions) {
                        #is the IP in the range of the exclusions?
                        #with powershell 5.1 you need to use (Start|End)Range.IPAddressToString with powershell 7 and above you need to remove the .IPAddressToString
                        $inRange = IsIPinRange -StartRange $exclusion.StartRange.IPAddressToString -EndRange $exclusion.EndRange.IPAddressToString -IpToCheck $ip.ip
                        #There can be a list of exclusion when it was found in listitem 1 it will not be in listitem 2, hence the use of the sentinelvalue
                        if ($inRange -and !$exclusionFound) {
                            $exclusionFound = $true
                        }
                    }
                    #when the exclusion is not found then mark the IP for deletion
                    if (!$exclusionFound) {
                        $remove = $true;
                    }
                }
                #when there are no exclusions mark the IP for deletion
                else {
                    $remove = $true
                }
                #check if the IP has a reservation in the DHCP scope
                if ($remove) {
                    foreach ($reservation in $reservations) {
                        if ($reservation.IPAddress -eq $ip.ip) {
                            $remove = $false
                            break #code optimization stop iterating when value found
                        }
                    }
                }
                #if it is not marked for deletion check if it is still in the leases
                if ($remove) {
                    foreach ($lease in $leases) {
                        if ($lease.IPAddress -eq $ip.ip) {
                            $remove = $false
                            break #code optimization stop iterating when value found
                        }
                    }
                }
                #remove the IP in IPAM        
                if ($remove) {
                    Write-Output "Removing IP $($ip.ip)"
                    Remove-PhpIpamAddress -id $ip.id
                }
            }
        }

        #sync the DHCP lease information into IPAM
        if ($leases) {
            Update-IPAM -DhcpList $leases -IpamSubnetId $ipamSubnetObject.id
        }

        #sync the DHCP reservations into IPAM
        if ($reservations) {
            Update-IPAM -DhcpList $reservations -IpamSubnetId $ipamSubnetObject.id
        }
    }
}

#clean up
Remove-phpipamSession