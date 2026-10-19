local M = {}
function M.band(a,b) return (a & b) & 0xffffffff end
function M.bxor(a,b) return (a ~ b) & 0xffffffff end
function M.bor(a,b,...)
  local value=a | b
  for _,operand in ipairs({...}) do value=value | operand end
  return value & 0xffffffff
end
function M.rshift(a,n) return (a & 0xffffffff) >> (n % 32) end
function M.lshift(a,n) return (a << (n % 32)) & 0xffffffff end
return M
