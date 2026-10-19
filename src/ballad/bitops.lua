-- Lua 5.1 fallback; native operators live in flavor files.
local M = {}
local function combine(a,b,mode)
  a,b=a%4294967296,b%4294967296
  local value,place=0,1
  for _=1,32 do
    local x,y=a%2,b%2
    if (mode=="and" and x==1 and y==1) or (mode=="or" and (x==1 or y==1)) or (mode=="xor" and x~=y) then value=value+place end
    a,b,place=math.floor(a/2),math.floor(b/2),place*2
  end
  return value
end
function M.band(a,b) return combine(a,b,"and") end
function M.bxor(a,b) return combine(a,b,"xor") end
function M.bor(a,b,...)
  local value=combine(a,b,"or")
  for _,operand in ipairs({...}) do value=combine(value,operand,"or") end
  return value
end
function M.rshift(a,n) return math.floor((a%4294967296)/2^(n%32)) end
function M.lshift(a,n) return (a*2^(n%32))%4294967296 end
return M
