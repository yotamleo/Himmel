'use strict';
// HIMMEL-1448: the ONE definition of "this registry lane is wizard/profile
// managed", shared by the resolver (resolve.mjs), the force-on consent
// (set-lane-override.mjs) and `himmelctl config get` (bin.js) so they cannot
// disagree. CommonJS so both the ESM and CJS callers can load it. Fail closed:
// only an absent marker or a literal `false` leaves a lane unmanaged; any other
// value (typo'd "false", 0, null) counts as managed.
function isProfileManaged(lane) {
  return lane?.profileManaged !== undefined && lane.profileManaged !== false;
}
module.exports = { isProfileManaged };
