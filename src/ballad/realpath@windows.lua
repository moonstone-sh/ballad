local process = require("ballad.process")
local path = require("ballad.path")
local script = [=[
param([string]$Directory)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class BalladCanonicalPath {
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder result, uint size, uint flags);
  public static string Resolve(string directory) {
    using(var handle=CreateFileW(directory,0,7,IntPtr.Zero,3,0x02000000,IntPtr.Zero)) {
      if(handle.IsInvalid) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
      var text=new StringBuilder(32768);
      uint length=GetFinalPathNameByHandleW(handle,text,(uint)text.Capacity,0);
      if(length==0) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
      if(length>=text.Capacity) throw new InvalidOperationException("canonical path exceeds buffer");
      return text.ToString();
    }
  }
}
'@
[BalladCanonicalPath]::Resolve($Directory)
]=]
return { resolve = function(directory)
  local temporary = os.tmpname()
  os.remove(temporary)
  temporary = temporary .. ".ps1"
  local file = assert(io.open(temporary, "wb"))
  assert(file:write(script)); assert(file:close())
  local ok, result = pcall(process.capture_run, { tool="powershell.exe", args={
    "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", temporary, path.absolute(directory),
  } })
  os.remove(temporary)
  if not ok then error(result, 0) end
  assert(result.exit_code == 0, "cannot resolve directory: " .. directory .. ": " .. result.stderr)
  local resolved = result.stdout:gsub("\\", "/")
  if resolved:sub(1,8) == "//?/UNC/" then resolved = "//" .. resolved:sub(9)
  elseif resolved:sub(1,4) == "//?/" then resolved = resolved:sub(5) end
  return path.normalize(resolved)
end }
