local partiture = require("ballad.partiture")

-- Public Ballad API entrypoint.
-- require("ballad") returns the partiture builder.
return {
  partiture = partiture.partiture,
}
