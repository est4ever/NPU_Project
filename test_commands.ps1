# Test script for Handle-InlineCommand
. .\npu_cli.ps1

Write-Host "Testing command recognition:"
Write-Host "Testing '/status':"
$result = Handle-InlineCommand -Input '/status'
Write-Host "Result: $result"

Write-Host "Testing 'status':"
$result = Handle-InlineCommand -Input 'status'
Write-Host "Result: $result"

Write-Host "Testing '/help':"
$result = Handle-InlineCommand -Input '/help'
Write-Host "Result: $result"

Write-Host "Testing 'help':"
$result = Handle-InlineCommand -Input 'help'
Write-Host "Result: $result"

Write-Host "Testing 'random text':"
$result = Handle-InlineCommand -Input 'random text'
Write-Host "Result: $result"