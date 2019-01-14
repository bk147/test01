<#
.Synopsis
   Create a new virtual Windows 2012 R2 server 
.DESCRIPTION
   Will create a new Windows 2012 R2 server in the VMware cluster.
   When the server has been created it will reboot a few times until the default settings has been applied.
   It takes about 5 minutes to provision the server - and 2-5 minutes for the configuration to basic server.
   The server is not added to a domain.
   You need rights on the VMWare Cluster to successfully run this command!
.EXAMPLE
   New-VMServer -Name bktest01
   Uses default parameters
.EXAMPLE
   New-VMServer -Name bktest02 -VLanName dc-addc-01 -IPAddress 172.25.14.32/27 -Datacenter slvd -Password MySupersecretPassword -Owner bkadmin@its.aau.dk -NoBackup -StartVm
   Creates a new Server with ip address 172.25.14.32 and mask length 27 on vlan dc-addc-01 in the slvd datacenter.
   We dont want Veeam to take backup of the server as its a short test and we want it to be started at once. The owner is added as a tag to the VM.
#>
function New-VMServer
{
    [CmdletBinding()]
    [Alias()]
    [OutputType([int])]
    Param
    (
        #The VMName is mandatory and will be used both for the VM and the OS name
        [Parameter(Mandatory = $true,ValueFromPipelineByPropertyName=$true)]
        [string]$Name,

        #If VLAN not specified - will use test vlan
        #Use 'Get-VirtualPortGroup -Name dc*' to get allowed vlan names...
        [Parameter(Mandatory = $false,ValueFromPipelineByPropertyName=$true)]
        [string]$VlanName,

        # Format: <x.y.z.w>/<subnet length>: ex 172.25.16.52/27
        [Parameter(Mandatory = $false,ValueFromPipelineByPropertyName=$true)]
        [ValidatePattern("\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}")] #Basic Validation...
        [string]$IPAddress,

        # Datacenter for the guest - default is dc2 (possible values: slvd eller dc2)
        [Parameter(Mandatory = $false,ValueFromPipelineByPropertyName=$true)]
        [ValidateSet('slvd', 'dc2')]
        [string]$Datacenter = 'dc2',

        # Password for the guest operating system
        [Parameter(Mandatory = $false,ValueFromPipelineByPropertyName=$true)]
        [string]$Password,

        # Owner is optional, but should be used for the VM Tag
        [Parameter(Mandatory = $false,ValueFromPipelineByPropertyName=$true)]
        [string]$Owner,

        # Start the VM after creation
        [Parameter(Mandatory = $false,ValueFromPipelineByPropertyName=$true)]
        [switch]$StartVm = $true,

        #Do not use Veeam to backup the vm
        [Parameter(Mandatory = $false,ValueFromPipelineByPropertyName=$true)]
        [switch]$NoBackup = $false
    )

    Begin
    {
        #We have to remove the Hyper-V module from the current session as there is a nameconflict with VMWare
        Remove-Module Hyper-V -ErrorAction SilentlyContinue

        Add-PSSnapin VMware.VimAutomation.Core
        #Get-Command -Module VMware.VimAutomation.Core

        $null = Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope User -Confirm:$false

        #Server used for looking up info about the $owner - has to be better (not hardcoded!)
        $adlookupserver = "srv-dc02.srv.aau.dk:3268"
        $dnsservers = @("172.18.16.17")

        $dc1srv = 'esx-vcsa02.srv.aau.dk'  #Cluster DC2
        $dc2srv = 'esx-vcsa01.srv.aau.dk'  #Cluster SLVD

        #Get-Template | ? {$_.Name -like "ws*"}
        #$template = 'ws2012r2_template'
        $template = 'ws2012r2_template_vmware'
    }
    Process
    {
        Write-Verbose "[Script version 1.0.3.0]"
        "Creating $Name in $datacenter..."

        if ($datacenter -eq 'dc2') {
            $visrv = $dc2srv #Cluster DC2
        } else {
            $visrv = $dc1srv #Cluster SLVD
        }
        Write-Verbose "Connecting to VIServer $visrv..."
        $null = Connect-VIServer $visrv

        if ($owner -ne "") {
            try {
                $tag = Get-Tag $owner -Server $dc2srv -ErrorAction Stop
            } catch {
                Write-Verbose "Check for $owner in AD..."
                $smtpowner = "smtp:$owner"
                $obj = Get-ADObject -Filter {(ProxyAddresses -eq $smtpowner)} -Properties DisplayName -Server $adlookupserver
                if ($obj -ne $empty) {
                    $tag = Get-TagCategory -Name "Owner" | New-Tag -Name $owner -Description $obj.DisplayName
                } else {
                    Write-Error "$owner does not exists - stopping creating the vm..."
                }
            }
        }

        #Create Temporary OS Customization...
        if ($Password -ne "") {
            $oscs = New-OSCustomizationSpec -Workgroup 'ITS' -FullName 'Brian Kirkegaard' -OrgName 'AAU,ITS' -ChangeSid:$true -TimeZone "100" -AdminPassword $Password
        } else {
            $oscs = New-OSCustomizationSpec -Workgroup 'ITS' -FullName 'Brian Kirkegaard' -OrgName 'AAU,ITS' -ChangeSid:$true -TimeZone "100" -AdminPassword 'P@ssw0rd!'
        }

        #Add ip information if available...
        if ($ipaddress -ne "") {
            $strIP = $ipaddress.split('/')[0]
            $strIPlen = $ipaddress.Split('/')[1]
            $strIPgw = GetGateway $strIP $strIPlen
            $strIPMask = GetSubnetMask $strIPlen
            Write-Verbose "IP info: $strIP;$strIPlen;$strIPgw;$strIPMask"
            $oscs | Get-OSCustomizationNicMapping | Set-OSCustomizationNicMapping -IpMode UseStaticIP -IPAddress $strIP -SubnetMask $strIPMask -DefaultGateway $strIPgw -Dns $dnsservers
        }

        Write-Verbose "Getting best datastore - with most space - for the server..."
        $ds = ((Get-DataStoreCluster -Server $visrv -Name vm-its-gold* | Get-TagAssignment).Entity | Sort-Object -Property FreeSpaceGB)[-1]
        Write-Verbose "Getting resource pool for virtual machine..."
        $viClusterName = ($ds | Get-TagAssignment).Tag.Name
        $rp = Get-ResourcePool -Server $visrv | ? {$_.Parent.Name -eq $viClusterName}
        Write-Verbose "Creating the virtual server..."

        $newvm = New-VM -Name $Name -Template $template -ResourcePool $rp -Datastore $ds -Server $visrv -OSCustomizationSpec $oscs
        $oscs | Remove-OSCustomizationSpec -Confirm:$false

        if ($NoBackup) {
            #Veem backup is not used if this tag is included in the vm...
            $testtag = Get-Tag -Name "Veeam-No-Backup" -Server $visrv
            $null = $newvm | New-TagAssignment -Tag $testtag
        }

        #Set tag for the VM - needs some work as only the listed (using Get-Tag) can be used!
        if ($tag -ne $empty) { $null = $newvm | New-TagAssignment -Tag $tag } else { Write-Verbose "No tag for owner <$owner> - will not set tag!" }

        #Change default vlan if defined
        #
        # !!Should test for existence of vlan (before creation!)
        #
        if ($vlanname -ne "") {
            $adapter = $newvm | Get-NetworkAdapter
            if ($adapter.Count -ne 1) {
                Write-Error "More than one network adapter - will not change"
            } else {
                $adapter | Set-NetworkAdapter -Portgroup $vlanname -Confirm:$false
            }
        }

        #Start the vm if asked for...
        if ($startvm) {
            $newvm | Start-VM
        }
    }
    End
    {
    }
}

<#
.Synopsis
   Find VLans in the VMWare clusters
.DESCRIPTION
   Find out which VLans are available in the AAU/ITS VMWare Production Clusters
.EXAMPLE
   Find-VMVlans
   Returns all VMVlans on the VMWare cluster
.EXAMPLE
   Find-VMVlans dc
   Returns all VMVlans which contains 'dc' in the name
.EXAMPLE
   Find-VMVlans *01
   Returns all VMVlans which ends with '01'
#>
function Find-VMVLans
{
    [CmdletBinding()]
    [Alias()]
    [OutputType([string[]])]
    Param
    (
        # VLanName can contain the wildcard '*' character - if unused we search for all occurrences of the string.
        # If no VLanName is defined - all VLan names are returned...
        [Parameter(Mandatory=$false,
                   ValueFromPipelineByPropertyName=$true)]
        [string]
        $VLanName
    )

    Begin
    {
        #We have to remove the Hyper-V module from the current session as there is a nameconflict with VMWare
        Remove-Module Hyper-V -ErrorAction SilentlyContinue

        Add-PSSnapin VMware.VimAutomation.Core

        $null = Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope User -Confirm:$false

        $dc2srv = 'esx-vcsa01.srv.aau.dk'  #Cluster SLVD
        $dc1srv = 'esx-vcsa02.srv.aau.dk'  #Cluster DC2

        Write-Verbose "Connecting to VIServers..."
        $null = Connect-VIServer $dc1srv
        $null = Connect-VIServer $dc2srv
    }
    Process
    {
        #Use 'Get-VirtualPortGroup -Name dc*' to get allowed vlan names...
        if ($VLanName -eq "") {
            Get-VirtualPortGroup | ? {$_.Key -like "dvportgroup*"} | Select-Object Name,DataCenter,@{Name='Vlan';Expression={$_.ExtensionData.Config.DefaultPortConfig.Vlan.VlanId}}
        } else {
            if ($VLanName.Contains('*')) {
                Get-VirtualPortGroup -Name $VLanName | ? {$_.Key -like "dvportgroup*"} | Select-Object Name,DataCenter,@{Name='Vlan';Expression={$_.ExtensionData.Config.DefaultPortConfig.Vlan.VlanId}}
            } else {
                Get-VirtualPortGroup -Name "*$VLanName*" | ? {$_.Key -like "dvportgroup*"} | Select-Object Name,DataCenter,@{Name='Vlan';Expression={$_.ExtensionData.Config.DefaultPortConfig.Vlan.VlanId}}
            }
        }
    }
    End
    {
    }
}

<#
.Synopsis
   Returns all IP addresses associated with the virtual guest.
.DESCRIPTION
   Gets all IP adresses from VMTools on the virtual guest OS.
   The server must be running and you need rights on the VMWare Clusters to run this command.
.EXAMPLE
   Get-ITSVMIPAddress -vmname ad-dc00
   192.168.236.20
.EXAMPLE
   Get-VM ad* | Get-VMIpaddress
#>
Function Get-VMIPAddress {
    [CmdletBinding()]
    param (
        #The name of the vmware guest to query - NOT the DNS name!
        [Parameter(Mandatory = $true,ValueFromPipelineByPropertyName=$true)]
        [string]$Name
    )
    Begin{}
    Process {
        Remove-Module Hyper-V -ErrorAction SilentlyContinue

        Add-PSSnapin VMware.VimAutomation.Core

        $null = Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope User -Confirm:$false

        $dc2srv = 'esx-vcsa01.srv.aau.dk'  #Cluster SLVD
        $dc1srv = 'esx-vcsa02.srv.aau.dk'  #Cluster DC2

        Write-Verbose "Connecting to VIServer $dc1srv..."
        $null = Connect-VIServer $dc1srv #Cluster DLVD

        Write-Verbose "Connecting to VIServer $dc2srv..."
        $null = Connect-VIServer $dc2srv #Cluster DC2

        (Get-VM $Name).Guest.IPAddress
    }
    End {}
}

#####################
#Helper functions...#
#####################
    function toBinary ($dottedDecimal) {
        $dottedDecimal.split(".") | % { $binary=$binary + $([convert]::toString($_,2).padleft(8,"0")) }
        return $binary
    }

    function toDottedDecimal ($binary){
        do {$dottedDecimal += "." + [string]$([convert]::toInt32($binary.substring($i,8),2)); $i+=8 } while ($i -le 24)
        return $dottedDecimal.substring(1)
    }

    function GetGateway ($strIP, $length) {
        $ipBinary = toBinary $strIP
        toDottedDecimal $($ipBinary.Substring(0,$length).PadRight(31,"0") + 1)
    }

    function GetNetwork ($strIP, $length) {
        $ipBinary = toBinary $strIP
        toDottedDecimal $($ipBinary.Substring(0,$length).PadRight(32,"0"))
    }

    function GetSubnetMask($length) {
        $ipBinary = "".PadRight($length,'1').PadRight(32,'0')
        toDottedDecimal $ipBinary
    }
