###############################################################################
#
# SNMP tools for LOCKSTEP
# January 15, 2014, jsanders@lockstepgroup.com
#
###############################################################################
# based heavily on http://vwiki.co.uk/SNMP_and_PowerShell
###############################################################################
# functions




function Install-Assembly {
	<#
	.SYNOPSIS
	Installs a managed assembly to the .Net GAC.
	.DESCRIPTION
	This cmdlet installs a .Net managed assembly into the .Net Global Assembly Cache. Please note that this cmdlet requires elevation.
	.EXAMPLE
	Install-Assembly .\myassembly\bin\myassembly.dll
	.PARAMETER Path
	Path to the assembly that you would like to install.
	#>
	
	Param (
		[Parameter(Mandatory=$True,Position=1)]
			[string]$Path
	)
		
	[Reflection.Assembly]::Load("System.EnterpriseServices, Version=2.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a") | Out-Null
	$publish = New-Object System.EnterpriseServices.Internal.Publish
	$InstallToGac = $publish.GacInstall( (Resolve-Path $Path).Path )
	
	# todo: how to confirm success?
}



function New-GenericObject {
	# Creates an object of a generic type - see http://www.leeholmes.com/blog/2006/08/18/creating-generic-types-in-powershell/
	# this is only used for powershell v2 and earlier

	param(
		[string] $typeName = $(throw "Please specify a generic type name"),
		[string[]] $typeParameters = $(throw "Please specify the type parameters"),
		[object[]] $constructorParameters
	)

	## Create the generic type name
	$genericTypeName = $typeName + '`' + $typeParameters.Count
	$genericType = [Type] $genericTypeName

	if(-not $genericType) {
		throw "Could not find generic type $genericTypeName"
	}

	## Bind the type arguments to it
	[type[]] $typedParameters = $typeParameters
	$closedType = $genericType.MakeGenericType($typedParameters)
	if(-not $closedType) {
		throw "Could not make closed type $genericType"
	}

	## Create the closed version of the generic type
	,[Activator]::CreateInstance($closedType, $constructorParameters)
}



function HelperCreateGenericList {
	if ($Host.Version.Major -le 2) {
		# PowerShell v1 and v2
		return New-GenericObject System.Collections.Generic.List Lextm.SharpSnmpLib.Variable
	} elseif ($Host.Version.Major -gt 2) {
		# PowerShell v3+
		return New-Object 'System.Collections.Generic.List[Lextm.SharpSnmpLib.Variable]'
	}$
}



function HelperValidateOrResolveIP ($TargetIP) {
	$ParsedIP = [Net.IPAddress]::Parse("0.0.0.0")
	try {
		[Net.IPAddress]::TryParse([Net.IPAddress]::Parse($TargetIP),[ref]$ParsedIP) | Out-Null
		
		# if this runs, the target IP here is valid; turn it into an object
		$TargetIP = $ParsedIP
	} catch {
		# if it errors and fires this catch, we need to try to resolve the name
		$ParsedIP = [Net.Dns]::GetHostEntry($TargetIP)[0].AddressList[0]
	}
	
	$ParsedIP
}



function Invoke-SnmpGet {
	<#
	.SYNOPSIS
	Performs an SNMP GET query against the target device.
	.DESCRIPTION
	This cmdlet uses the SharpSNMP library to perform direct SNMP GET queries against the target device and OID using the provided community string.
	.EXAMPLE
	Invoke-SnmpGet 10.10.35.40 publ1c 1.3.6.1.2.1.1.3.0
	.PARAMETER TargetDevice
	The IP or hostname of the target device.
	.PARAMETER CommunityString
	SNMP community string to use to query the target device.
	.PARAMETER ObjectIdentifiers
	SNMP OID(s) to query on the target device. For Invoke-SnmpGet, this can be a single OID (string value) or an array of OIDs (string values).
	.PARAMETER UDPport
	UDP Port to use to perform SNMP queries.
	.PARAMETER Timeout
	Time to wait before expiring SNMP call handles.
	#>
	
	Param (
		[Parameter(Mandatory=$True,Position=1)]
			[string]$TargetDevice,
			
        [Parameter(Mandatory=$true,Position=2)]
			[string]$CommunityString = "public",
			
		[Parameter(Mandatory=$True,Position=3)]
			$ObjectIdentifiers,
			
		[Parameter(Mandatory=$False)]
			[int]$UDPport = 161,
			
        [Parameter(Mandatory=$False)]
			[int]$Timeout = 3000
	)


	if (![Reflection.Assembly]::LoadWithPartialName("SharpSnmpLib")) {
		Write-Error "Missing Lextm.SharpSnmpLib Assembly; is it installed?"
		return
	}
		
	# Create endpoint for SNMP server
	$TargetIPEndPoint = New-Object System.Net.IpEndPoint ($(HelperValidateOrResolveIP $TargetDevice), $UDPport)

	# Create a generic list to be the payload
	$DataPayload = HelperCreateGenericList
	
	# Convert each OID to the proper object type and add to the list
	foreach ($OIDString in $ObjectIdentifiers) {
		$OIDObject = New-Object Lextm.SharpSnmpLib.ObjectIdentifier ($OIDString)
		$DataPayload.Add($OIDObject)
	}

	# Use SNMP v2
	$SnmpVersion = [Lextm.SharpSnmpLib.VersionCode]::V2

	# Perform SNMP Get
	try {
		$ReturnedSet = [Lextm.SharpSnmpLib.Messaging.Messenger]::Get($SnmpVersion, $TargetIPEndPoint, $CommunityString, $DataPayload, $Timeout)
	} catch {
	
		# can we handle this more gracefully?
		Write-Host "SNMP Get error: $_"
		Return $null
	}

	# clean up return data
	$Result = @()
	foreach ($Entry in $ReturnedSet) {
		$RecordLine = "" | Select OID, Data
		$RecordLine.OID = $Entry.Id.ToString()
		$RecordLine.Data = $Entry.Data.ToString()
		$Result += $RecordLine
	}

	$Result
}



function Invoke-SnmpSet {
	<#
	.SYNOPSIS
	Performs an SNMP SET query against the target device.
	.DESCRIPTION
	This cmdlet uses the SharpSNMP library to perform direct SNMP SET queries against the target device and OID using the provided community string.
	.EXAMPLE
	Invoke-SnmpSet 10.10.35.40 publ1c 1.3.6.1.2.1.1.3.0 123456 "i"
	.EXAMPLE
	Invoke-SnmpSet -TargetDevice 10.10.35.40 -CommunityString publ1c -ObjectIdentifier 1.3.6.1.2.1.1.3.0 -OIDValue 123456 -DataType "i"
	.PARAMETER TargetDevice
	The IP or hostname of the target device.
	.PARAMETER CommunityString
	SNMP community string to use to query the target device.
	.PARAMETER ObjectIdentifier
	SNMP OID to query on the target device. For Invoke-SnmpSet, this can only be a single OID (string value). Until I maybe fix it someday
	.PARAMETER OIDValue
	The value to set the provided OID to.
	.PARAMETER DataType
	Data type of the provided value. Valid values:
		i: INTEGER
		u: unsigned INTEGER
		t: TIMETICKS
		a: IPADDRESS
		o: OBJID
		s: STRING
		x: HEX STRING
		d: DECIMAL STRING
		n: NULL VALUE
	.PARAMETER UDPport
	UDP Port to use to perform SNMP queries.
	.PARAMETER Timeout
	Time in milliseconds to wait before expiring SNMP call handles. For unlimited timeout, provide 0 or -1.
	#>
	
	Param (
		[Parameter(Mandatory=$True,Position=1)]
			[string]$TargetDevice,
			
        [Parameter(Mandatory=$true,Position=2)]
			[string]$CommunityString = "public",
			
		[Parameter(Mandatory=$True,Position=3)]
			[string]$ObjectIdentifier,
			
		[Parameter(Mandatory=$True,Position=4)]
			$OIDValue,
			
		[Parameter(Mandatory=$True,Position=5)]
			[ValidateSet("i","u","t","a","o","s","x","d","n")]
			[string]$DataType,
			
		[Parameter(Mandatory=$False)]
			[int]$UDPport = 161,
			
        [Parameter(Mandatory=$False)]
			[int]$Timeout = 3000
	)


	if (![Reflection.Assembly]::LoadWithPartialName("SharpSnmpLib")) {
		Write-Error "Missing Lextm.SharpSnmpLib Assembly; is it installed?"
		return
	}
	
	# Create endpoint for SNMP server
	$TargetIPEndPoint = New-Object System.Net.IpEndPoint ($(HelperValidateOrResolveIP $TargetDevice), $UDPport)

	# Create a generic list to be the payload
	$DataPayload = HelperCreateGenericList
	
	# Convert each OID to the proper object type and add to the list
	<# foreach ($OIDString in $ObjectIdentifiers) {
		$OIDObject = New-Object Lextm.SharpSnmpLib.ObjectIdentifier ($OIDString)
		$DataPayload.Add($OIDObject)
	} #>
	
	# this is where the foreach would begin
	
	$ThisOID = New-Object Lextm.SharpSnmpLib.ObjectIdentifier $ObjectIdentifier
	
	switch ($DataType) {
		"i" { $ThisData = New-Object Lextm.SharpSnmpLib.Integer32 ([int] $OIDValue) }
		"u" { $ThisData = New-Object Lextm.SharpSnmpLib.Gauge32	 ([uint32] $OIDValue) }
		"t" { $ThisData = New-Object Lextm.SharpSnmpLib.TimeTicks ([uint32] $OIDValue) }
		"a" { $ThisData = New-Object Lextm.SharpSnmpLib.IP ([Net.IPAddress]::Parse($OIDValue)) }
		"o" { $ThisData = New-Object Lextm.SharpSnmpLib.ObjectIdentifier ($OIDValue) }
		"s" { $ThisData = New-Object Lextm.SharpSnmpLib.OctetString ($OIDValue) }
		"x" { $ThisData = New-Object Lextm.SharpSnmpLib.OctetString ([Lextm.SharpSnmpLib.ByteTool]::Convert($OIDValue)) }
		"d" { $ThisData = New-Object Lextm.SharpSnmpLib.OctetString ([Lextm.SharpSnmpLib.ByteTool]::ConvertDecimal($OIDValue)) } # not sure about this one actually working...
		"n" { $ThisData = New-Object Lextm.SharpSnmpLib.Null }
		# default { }
	}
	
	$OIDObject = New-Object Lextm.SharpSnmpLib.Variable ($ThisOID, $ThisData)
	
	# this is where the foreach would end
	
	$DataPayload.Add($OIDObject)
	

	# Use SNMP v2
	$SnmpVersion = [Lextm.SharpSnmpLib.VersionCode]::V2

	# Perform SNMP Get
	try {
		$ReturnedSet = [Lextm.SharpSnmpLib.Messaging.Messenger]::Set($SnmpVersion, $TargetIPEndPoint, $CommunityString, $DataPayload, $Timeout)
	} catch {
	
		# can we handle this more gracefully?
		Write-Host "SNMP Set error: $_"
		Return $null
	}

	# clean up return data 
	$Result = @()
	foreach ($Entry in $ReturnedSet) {
		$RecordLine = "" | Select OID, Data
		$RecordLine.OID = $Entry.Id.ToString()
		$RecordLine.Data = $Entry.Data.ToString()
		$Result += $RecordLine
	}

	$Result
}



function Invoke-SnmpWalk  {
    Param (
		[Parameter(Mandatory=$True,Position=1)]
			[string]$TargetDevice,
			
        [Parameter(Mandatory=$true,Position=2)]
			[string]$CommunityString = "public",
			
		[Parameter(Mandatory=$True,Position=3)]
			[string]$ObjectIdentifier,
			
		[Parameter(Mandatory=$False)]
			[int]$UDPport = 161,
			
        [Parameter(Mandatory=$False)]
			[int]$Timeout = 3000
	)
	# $sOIDstart
	# $TimeOut is in msec, 0 or -1 for infinite

	# Create OID object
	$oid = New-Object Lextm.SharpSnmpLib.ObjectIdentifier ($ObjectIdentifier)

	# Create OID variable list
	if ($Host.Version.Major -le 2) {
		# PowerShell v1 and v2
		$vList = New-GenericObject System.Collections.Generic.List Lextm.SharpSnmpLib.Variable
	} elseif ($Host.Version.Major -gt 2) {
		# PowerShell v3+
		$vList = New-Object 'System.Collections.Generic.List[Lextm.SharpSnmpLib.Variable]'
	}

	# Create endpoint for SNMP server
	$ip = [System.Net.IPAddress]::Parse($TargetDevice)
	$svr = New-Object System.Net.IpEndPoint ($ip, 161)

	# Use SNMP v2 and walk mode WithinSubTree (as opposed to Default)
	$ver = [Lextm.SharpSnmpLib.VersionCode]::V2
	$walkMode = [Lextm.SharpSnmpLib.Messaging.WalkMode]::WithinSubtree

	# Perform SNMP Get
	try {
		[Lextm.SharpSnmpLib.Messaging.Messenger]::Walk($ver, $svr, $CommunityString, $oid, $vList, $TimeOut, $walkMode) | Out-Null
	} catch [Lextm.SharpSnmpLib.Messaging.TimeoutException] {
		Write-Host "SNMP Get on $TargetDevice timed-out"
		Return $null
	} catch {
		Write-Host "SNMP Walk error: $_"
		Return $null
	}

	$res = @()
	foreach ($var in $vList) {
		$line = "" | Select OID, Data
		$line.OID = $var.Id.ToString()
		$line.Data = $var.Data.ToString()
		$res += $line
	}

	$res
}


###############################################################################


<#

#Invoke-SNMPget 10.26.150.251 1.3.6.1.4.1.21013.1.2.12.1.2.22.0 Notouchy

$OIDs = @(
	'1.3.6.1.2.1.1.5.0', # sysName
	'1.3.6.1.2.1.1.1.0', # sysDescr
	'1.3.6.1.4.1.21013.1.2.12.1.2.22.0', # global num stations
	'1.3.6.1.4.1.21013.1.2.28.16.1.4.0' # array model
	)

$CommunityString = 'Notouchy'

$TargetAP = '10.26.150.251'
	
Invoke-SNMPget $TargetAP $OIDs $CommunityString

# 1.3.6.1.4.1.21013.1.2.12.1.1.1.4 = iap num stations; number of clients per radio
# 1.3.6.1.4.1.21013.1.2.12.1.1.1.7 = iap tx pwr; Maximum Tx power output from radio
# 1.3.6.1.4.1.21013.1.2.28.21.1.3 = system temp celsius; not sure what the components actually are yet
# 1.3.6.1.4.1.21013.1.2.24.6.1.7 = spectrum analysis average rssi; Average RSSI
Invoke-SnmpWalk $TargetAP 1.3.6.1.4.1.21013.1.2.12.1.1.1.4 $CommunityString


Invoke-SnmpGet 10.10.35.40 1.3.6.1.2.1.1.3.0 publ1c



#>