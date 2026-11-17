#requires -Version 5.1
# Read the BLE Battery Level characteristic (0x2A19) directly from the mouse.
# Pass the mouse's Bluetooth address (12 hex digits, no separators), e.g.
#   .\read_gatt.ps1 -Address AABBCCDDEEFF
# Find it in 设置 > 蓝牙和设备 > 设备属性, or with Get-PnpDevice -Class Bluetooth.
param([string]$Address)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Address) -or $Address -notmatch '^[0-9A-Fa-f]{12}$') {
    throw 'Usage: read_gatt.ps1 -Address <12 hex digits>, e.g. -Address AABBCCDDEEFF'
}
Add-Type -AssemblyName System.Runtime.WindowsRuntime

$asTaskOperation = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]

function Await {
    param($Op, [Type]$T)
    $task = $asTaskOperation.MakeGenericMethod($T).Invoke($null, @($Op))
    try { $null = $task.Wait(-1) } catch {
        $e = $_.Exception
        while ($e.InnerException) { $e = $e.InnerException }
        throw "INNER: $($e.GetType().Name): $($e.Message) (0x$('{0:X8}' -f $e.HResult))"
    }
    return $task.Result
}

$null = [Windows.Devices.Bluetooth.BluetoothLEDevice, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
$null = [Windows.Devices.Bluetooth.BluetoothCacheMode, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
$null = [Windows.Devices.Bluetooth.GenericAttributeProfile.GattDeviceServicesResult, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
$null = [Windows.Devices.Bluetooth.GenericAttributeProfile.GattCharacteristicsResult, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
$null = [Windows.Devices.Bluetooth.GenericAttributeProfile.GattReadResult, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.DataReader, Windows.Storage.Streams, ContentType = WindowsRuntime]

$addr = [Convert]::ToUInt64($Address, 16)
Write-Output ("address: 0x{0:X12}" -f $addr)

$device = Await ([Windows.Devices.Bluetooth.BluetoothLEDevice]::FromBluetoothAddressAsync($addr)) ([Windows.Devices.Bluetooth.BluetoothLEDevice])
if ($null -eq $device) { Write-Output 'RESULT: device-null'; return }
Write-Output "device: $($device.Name)  status=$($device.ConnectionStatus)"

$services = Await ($device.GetGattServicesAsync([Windows.Devices.Bluetooth.BluetoothCacheMode]::Uncached)) ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattDeviceServicesResult])
Write-Output "services: status=$($services.Status) count=$($services.Services.Count)"

$battery = $null
foreach ($s in $services.Services) {
    Write-Output ("  service {0}" -f $s.Uuid)
    if ($s.Uuid -eq [Guid]'0000180f-0000-1000-8000-00805f9b34fb') { $battery = $s }
}
if ($null -eq $battery) { Write-Output 'RESULT: no-battery-service'; return }

$chars = Await ($battery.GetCharacteristicsAsync([Windows.Devices.Bluetooth.BluetoothCacheMode]::Uncached)) ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattCharacteristicsResult])
Write-Output "characteristics: status=$($chars.Status) count=$($chars.Characteristics.Count)"

foreach ($c in $chars.Characteristics) {
    Write-Output ("  char {0}" -f $c.Uuid)
    if ($c.Uuid -ne [Guid]'00002a19-0000-1000-8000-00805f9b34fb') { continue }
    $read = Await ($c.ReadValueAsync([Windows.Devices.Bluetooth.BluetoothCacheMode]::Uncached)) ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattReadResult])
    Write-Output "  read status=$($read.Status)"
    if ($null -ne $read.Value) {
        $reader = [Windows.Storage.Streams.DataReader]::FromBuffer($read.Value)
        $level = $reader.ReadByte()
        Write-Output "RESULT: battery=$level %"
    }
}
