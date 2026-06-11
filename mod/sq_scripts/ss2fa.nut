//============================================================================
//  SS2 Freelook mode - Squirrel side (NON-VR independent aim crosshair)
//
//  Reads config var "ss2fa_aim" published by flataim.dll:
//    "<valid> <wox> <woy> <woz> <wdx> <wdy> <wdz> <dyaw> <dpitch> <cu> <cv>"
//  valid=1 => Freelook active.
//    wo*  = ray world origin (camera)         -> projectile spawn
//    wd*  = ray world direction (unit)        -> projectile velocity
//    dyaw/dpitch = crosshair angular offset from view centre (deg) -> weapon CameraObj
//    cu/cv = crosshair screen position 0..1   -> crosshair draw
//
//  Core (projectile redirect) is complete and self-contained. The weapon-follow
//  and crosshair-draw reuse the proven SS2VR probe patterns — see marked spots.
//============================================================================

if(!("SS2FA" in getroottable())) ::SS2FA <- {};
if(!("weaponProxyObj" in SS2FA)) SS2FA.weaponProxyObj <- 0;
if(!("proxyValid" in SS2FA)) SS2FA.proxyValid <- false;
if(!("proxyWorldPos" in SS2FA)) SS2FA.proxyWorldPos <- null;
if(!("proxyFacing" in SS2FA)) SS2FA.proxyFacing <- null;
if(!("proxyRollRaw" in SS2FA)) SS2FA.proxyRollRaw <- 0.0;
if(!("proxyRollApplied" in SS2FA)) SS2FA.proxyRollApplied <- 0.0;
if(!("proxyRollSign" in SS2FA)) SS2FA.proxyRollSign <- 1.0;
if(!("proxyRollKill" in SS2FA)) SS2FA.proxyRollKill <- 0;
if(!("proxyViewPitchAtCreate" in SS2FA)) SS2FA.proxyViewPitchAtCreate <- 0.0;
if(!("dbgViewFwd" in SS2FA)) SS2FA.dbgViewFwd <- null;
if(!("dbgViewUp" in SS2FA)) SS2FA.dbgViewUp <- null;
if(!("dbgAim" in SS2FA)) SS2FA.dbgAim <- null;
if(!("dbgGunUp" in SS2FA)) SS2FA.dbgGunUp <- null;
if(!("dbgCamFacing" in SS2FA)) SS2FA.dbgCamFacing <- null;
if(!("dbgBank" in SS2FA)) SS2FA.dbgBank <- 0.0;
if(!("proxyHeadingRaw" in SS2FA)) SS2FA.proxyHeadingRaw <- 0.0;
if(!("proxyHeadingApplied" in SS2FA)) SS2FA.proxyHeadingApplied <- 0.0;
if(!("proxyHeadingBase" in SS2FA)) SS2FA.proxyHeadingBase <- 0.0;
if(!("proxyHeadingFlipX" in SS2FA)) SS2FA.proxyHeadingFlipX <- 0;
if(!("proxyBasisForward" in SS2FA)) SS2FA.proxyBasisForward <- null;
if(!("proxyBasisRight" in SS2FA)) SS2FA.proxyBasisRight <- null;
if(!("proxyBasisUp" in SS2FA)) SS2FA.proxyBasisUp <- null;
if(!("proxyAxisDrawFailureLogged" in SS2FA)) SS2FA.proxyAxisDrawFailureLogged <- false;
if(!("proxyDarkMatrix" in SS2FA)) SS2FA.proxyDarkMatrix <- 0;
if(!("effectViewmodelActive" in SS2FA)) SS2FA.effectViewmodelActive <- false;
if(!("effectFailureLogged" in SS2FA)) SS2FA.effectFailureLogged <- false;
if(!("meleeViewmodelInstalled" in SS2FA)) SS2FA.meleeViewmodelInstalled <- false;
if(!("meleeViewmodelActive" in SS2FA)) SS2FA.meleeViewmodelActive <- false;
if(!("meleeViewmodelLastActiveTime" in SS2FA)) SS2FA.meleeViewmodelLastActiveTime <- -999999;
if(!("lastCanvasRawX" in SS2FA)) SS2FA.lastCanvasRawX <- 0;
if(!("lastCanvasRawY" in SS2FA)) SS2FA.lastCanvasRawY <- 0;
// Measured ShockOverlay space (WorldToScreen calibration). The overlay's true dimensions are
// MEASURED at runtime instead of assumed (960-fixed vs height-normalized models both failed at
// some resolution): the camera-forward point always projects to the visual screen centre, so
// WorldToScreen(centre) * 2 = the engine's real overlay width/height at the current resolution.
if(!("overlayCalValid" in SS2FA)) SS2FA.overlayCalValid <- false;
if(!("overlayCalW" in SS2FA)) SS2FA.overlayCalW <- 0.0;
if(!("overlayCalH" in SS2FA)) SS2FA.overlayCalH <- 0.0;
if(!("overlayCalRawX" in SS2FA)) SS2FA.overlayCalRawX <- 0;
if(!("overlayCalRawY" in SS2FA)) SS2FA.overlayCalRawY <- 0;
if(!("overlayCalSampleX" in SS2FA)) SS2FA.overlayCalSampleX <- -1;
if(!("overlayCalSampleY" in SS2FA)) SS2FA.overlayCalSampleY <- -1;
if(!("overlayCalLogged" in SS2FA)) SS2FA.overlayCalLogged <- false;

const SS2FA_PI = 3.14159265358979;
const SS2FA_SCRIPT_REV = "20260610-overlay-worldtoscreen-cal";
const SS2FA_OVERLAY_CROSSHAIR = 22;
const SS2FA_OVERLAY_MODE_OFF = 0;
const SS2FA_OVERLAY_MODE_ON = 1;

function SS2FA_Raw(name)
{
    try {
        if(Engine.ConfigIsDefined(name)){
            local value = string();
            Engine.ConfigGetRaw(name, value);
            return value.tostring();
        }
    } catch(e) {}
    return "";
}

function SS2FA_GetInt(name, defaultValue)
{
    try {
        if(Engine.ConfigIsDefined(name)){
            local value = int_ref();
            Engine.ConfigGetInt(name, value);
            return value.tointeger();
        }
    } catch(e) {}
    return defaultValue;
}

function SS2FA_GetFloat(name, defaultValue)
{
    try {
        if(Engine.ConfigIsDefined(name)){
            local value = float_ref();
            Engine.ConfigGetFloat(name, value);
            return value.tofloat();
        }
    } catch(e) {}
    return defaultValue;
}

function SS2FA_ReadAim()
{
    local raw = SS2FA_Raw("ss2fa_aim");
    if(raw == null || raw.len() == 0) return null;
    local p = split(raw, " ");
    if(p.len() < 7) return null;
    if(p[0].tointeger() == 0) return null;
    return {
        valid = true,
        wox = p[1].tofloat(), woy = p[2].tofloat(), woz = p[3].tofloat(),
        wdx = p[4].tofloat(), wdy = p[5].tofloat(), wdz = p[6].tofloat(),
        dyaw   = (p.len() > 7)  ? p[7].tofloat()  : 0.0,
        dpitch = (p.len() > 8)  ? p[8].tofloat()  : 0.0,
        cu     = (p.len() > 9)  ? p[9].tofloat()  : 0.5,
        cv     = (p.len() > 10) ? p[10].tofloat() : 0.5,
    };
}

function SS2FA_ClearAim()
{
    try { Debug.Command("set", "ss2fa_aim 0 0 0 0 0 0 1 0 0 0.5 0.5"); } catch(e) {}
}

function SS2FA_DegToDark(deg)
{
    while(deg < 0.0) deg += 360.0;
    while(deg >= 360.0) deg -= 360.0;
    return ((deg / 360.0) * 65535.0).tointeger();
}

function SS2FA_RadToDeg(radians)
{
    return radians * 57.2957795;
}

function SS2FA_DegToRad(degrees)
{
    return degrees * SS2FA_PI / 180.0;
}

function SS2FA_VecLen(v) { return sqrt(v.x * v.x + v.y * v.y + v.z * v.z); }

function SS2FA_NormalizeVec(v, fallback)
{
    local len = SS2FA_VecLen(v);
    if(len <= 0.0001) return fallback;
    return vector(v.x / len, v.y / len, v.z / len);
}

function SS2FA_Dot(a, b)
{
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

function SS2FA_Cross(a, b)
{
    return vector(
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x
    );
}

function SS2FA_ProjectOntoPlane(v, normal, fallback)
{
    local n = SS2FA_NormalizeVec(normal, vector(0.0, 1.0, 0.0));
    local d = SS2FA_Dot(v, n);
    local projected = vector(v.x - n.x * d, v.y - n.y * d, v.z - n.z * d);
    if(SS2FA_VecLen(projected) > 0.0001) return SS2FA_NormalizeVec(projected, fallback);

    local fd = SS2FA_Dot(fallback, n);
    return SS2FA_NormalizeVec(
        vector(fallback.x - n.x * fd, fallback.y - n.y * fd, fallback.z - n.z * fd),
        fallback
    );
}

function SS2FA_CameraWorldAxis(localAxis, fallback)
{
    try {
        local origin = Camera.CameraToWorld(vector(0.0, 0.0, 0.0));
        local point = Camera.CameraToWorld(localAxis);
        return SS2FA_NormalizeVec(
            vector(point.x - origin.x, point.y - origin.y, point.z - origin.z),
            fallback
        );
    } catch(e) {}
    return fallback;
}

function SS2FA_FlatCameraScreenBasis()
{
    local heading = 0.0;
    local pitch = 0.0;
    try {
        local f = Camera.GetFacing();
        // Camera.GetFacing() is (x=bank, y=pitch, z=heading) -- proven by [SS2FA-VDBG]:
        // f.x was always 0 (bank) while f.z varied with where the player faced. Reading
        // heading from f.x locked the view-forward to world-north, which rolled the gun
        // everywhere except when facing ~north. Heading is f.z.
        heading = SS2FA_SignedAngleDeg(f.z);
        pitch = SS2FA_SignedAngleDeg(f.y);
    } catch(e) {}

    local forward = SS2FA_DirFromHeadingPitchDeg(heading, pitch);
    local worldUp = vector(0.0, 0.0, 1.0);
    local right = SS2FA_Cross(forward, worldUp);
    if(SS2FA_VecLen(right) <= 0.0001){
        local h = heading * SS2FA_PI / 180.0;
        right = vector(cos(h), -sin(h), 0.0);
    }
    right = SS2FA_NormalizeVec(right, vector(1.0, 0.0, 0.0));
    local up = SS2FA_NormalizeVec(SS2FA_Cross(right, forward), worldUp);
    return {
        heading = heading,
        pitch = pitch,
        forward = forward,
        right = right,
        up = up
    };
}

// Rotate vector v by the shortest-arc rotation that carries unit fromV onto unit toV.
// (Quaternion-equivalent, via Rodrigues. Used to carry the view-up along to the aim.)
function SS2FA_RotateFromTo(fromV, toV, v)
{
    local a = SS2FA_NormalizeVec(fromV, vector(1.0, 0.0, 0.0));
    local b = SS2FA_NormalizeVec(toV, vector(1.0, 0.0, 0.0));
    local axis = SS2FA_Cross(a, b);
    local s = SS2FA_VecLen(axis);
    local c = SS2FA_Dot(a, b);
    if(s <= 0.000001) return v;            // parallel: no rotation needed
    axis = vector(axis.x / s, axis.y / s, axis.z / s);
    local cr = SS2FA_Cross(axis, v);
    local d = SS2FA_Dot(axis, v) * (1.0 - c);
    return vector(
        v.x * c + cr.x * s + axis.x * d,
        v.y * c + cr.y * s + axis.y * d,
        v.z * c + cr.z * s + axis.z * d
    );
}

// VIEW-RELATIVE facing: the locked view IS the horizon for the gun. The gun points at
// the crosshair (world aim) but stays upright relative to the SCREEN: its up = the
// view-up carried along the shortest-arc rotation from view-forward to the aim. A
// horizontal crosshair sweep rotates about view-up, which leaves the up unchanged ->
// pure view-relative yaw, zero roll, at any view pitch.
function SS2FA_DirToProxyFacingViewRelative(dx, dy, dz)
{
    local aim = SS2FA_NormalizeVec(vector(dx, dy, dz), vector(1.0, 0.0, 0.0));
    local basis = SS2FA_FlatCameraScreenBasis();    // locked-view forward/right/up
    // Screen-level construction: gun-right = cross(aim, viewUp) is horizontal on screen
    // (perpendicular to the view-up), and gun-up completes the basis. This is upright
    // relative to the SCREEN by definition. (The old shortest-arc carried view-up along a
    // tilted axis, which rolled it — exactly the bank blow-up the diagnostic showed.)
    local gunRight = SS2FA_NormalizeVec(SS2FA_Cross(aim, basis.up), basis.right);
    local gunUp = SS2FA_NormalizeVec(SS2FA_Cross(gunRight, aim), basis.up);

    local horiz = sqrt(aim.x * aim.x + aim.y * aim.y);
    local pitch = SS2FA_RadToDeg(atan2(-aim.z, horiz))
        + SS2FA_GetFloat("ss2fa_weapon_proxy_pitch_offset", 0.0);
    // Heading expressed as deviation from the locked view heading, so we can flip the
    // left/right sense without breaking the world direction (view_yaw_sign = -1 mirrors L/R).
    local aimHeading = SS2FA_WorldHeadingDeg(aim.x, aim.y);
    // Default -1.0: the engine's facing->orientation reflects the heading, so the gun's
    // rendered yaw must be reflected about the view heading to track the crosshair. (Live-tested.)
    local heading = basis.heading
        + SS2FA_SignedAngleDeg(aimHeading - basis.heading)
            * SS2FA_GetFloat("ss2fa_weapon_proxy_view_yaw_sign", -1.0)
        + SS2FA_GetFloat("ss2fa_weapon_proxy_heading_offset", 0.0);

    // bank=0 yields a world-upright gun; bank = signed roll from world-up to gunUp about the aim.
    local worldUp = vector(0.0, 0.0, 1.0);
    local upW = SS2FA_ProjectOntoPlane(worldUp, aim, worldUp);
    local refRight = SS2FA_Cross(aim, upW);
    local bank = SS2FA_RadToDeg(atan2(SS2FA_Dot(gunUp, refRight), SS2FA_Dot(gunUp, upW)))
            * SS2FA_GetFloat("ss2fa_weapon_proxy_view_up_sign", 1.0)
        + SS2FA_GetFloat("ss2fa_weapon_proxy_bank_offset", 0.0);

    SS2FA.proxyRollRaw = bank;
    SS2FA.proxyRollApplied = bank;
    SS2FA.proxyRollSign = SS2FA_GetFloat("ss2fa_weapon_proxy_view_up_sign", 1.0);
    SS2FA.proxyRollKill = 0;
    SS2FA.proxyBasisForward = aim;
    SS2FA.proxyBasisRight = gunRight;
    SS2FA.proxyBasisUp = gunUp;
    // Diagnostic capture (logged short + untruncated by [SS2FA-VDBG]).
    SS2FA.dbgViewFwd = basis.forward;
    SS2FA.dbgViewUp = basis.up;
    SS2FA.dbgAim = aim;
    SS2FA.dbgGunUp = gunUp;
    try { SS2FA.dbgCamFacing = Camera.GetFacing(); } catch(eCF) { SS2FA.dbgCamFacing = null; }
    SS2FA.dbgBank = bank;
    return vector(bank, pitch, heading);
}

function SS2FA_DirToProxyFacingWithUp(dx, dy, dz, desiredUp, desiredRight)
{
    local dir = SS2FA_NormalizeVec(vector(dx, dy, dz), vector(0.0, 1.0, 0.0));
    local headingRaw = SS2FA_WorldHeadingDeg(dir.x, dir.y);
    local heading = headingRaw + SS2FA_GetFloat("ss2fa_weapon_proxy_heading_offset", 0.0);
    local pitch = SS2FA_WorldPitchDeg(dir.x, dir.y, dir.z) + SS2FA_GetFloat("ss2fa_weapon_proxy_pitch_offset", 0.0);
    local bank = SS2FA_GetFloat("ss2fa_weapon_proxy_bank_offset", 0.0);
    local worldUp = vector(0.0, 0.0, 1.0);
    local fallbackRight = desiredRight;
    if(fallbackRight == null) fallbackRight = vector(1.0, 0.0, 0.0);

    local baseRight = SS2FA_ProjectOntoPlane(SS2FA_Cross(dir, worldUp), dir, fallbackRight);
    local baseUp = SS2FA_NormalizeVec(SS2FA_Cross(baseRight, dir), worldUp);
    local wantedUp = SS2FA_ProjectOntoPlane(desiredUp, dir, baseUp);
    local roll = SS2FA_RadToDeg(atan2(SS2FA_Dot(wantedUp, baseRight), SS2FA_Dot(wantedUp, baseUp)));
    local rollSign = SS2FA_GetFloat("ss2fa_weapon_proxy_roll_sign", -1.0);
    SS2FA.proxyRollRaw = roll;
    SS2FA.proxyRollApplied = roll * rollSign;
    SS2FA.proxyRollSign = rollSign;
    SS2FA.proxyRollKill = 0;
    SS2FA.proxyHeadingRaw = headingRaw;
    SS2FA.proxyHeadingApplied = heading;
    SS2FA.proxyHeadingBase = 0.0;
    SS2FA.proxyHeadingFlipX = 0;
    SS2FA.proxyDarkMatrix = 0;
    bank += SS2FA.proxyRollApplied;
    return vector(bank, pitch, heading);
}

function SS2FA_DirToProxyFacingRollKilled(dx, dy, dz, headingBaselineValid, headingBaseline)
{
    local dir = SS2FA_NormalizeVec(vector(dx, dy, dz), vector(0.0, 1.0, 0.0));
    local headingRaw = SS2FA_WorldHeadingDeg(dir.x, dir.y);
    local heading = SS2FA_ApplyProxyHeadingMirror(headingRaw, headingBaselineValid, headingBaseline)
        + SS2FA_GetFloat("ss2fa_weapon_proxy_heading_offset", 0.0);
    SS2FA.proxyHeadingApplied = heading;
    local pitch = SS2FA_WorldPitchDeg(dir.x, dir.y, dir.z) + SS2FA_GetFloat("ss2fa_weapon_proxy_pitch_offset", 0.0);
    SS2FA.proxyRollRaw = 0.0;
    SS2FA.proxyRollApplied = 0.0;
    SS2FA.proxyRollSign = SS2FA_GetFloat("ss2fa_weapon_proxy_roll_sign", 1.0);
    SS2FA.proxyRollKill = 1;
    SS2FA.proxyDarkMatrix = 0;
    return vector(0.0, pitch, heading);
}

function SS2FA_WorldHeadingDeg(dx, dy)
{
    return SS2FA_RadToDeg(atan2(dx, dy));
}

function SS2FA_DarkHeadingDeg(dx, dy)
{
    return SS2FA_RadToDeg(atan2(dy, dx));
}

function SS2FA_WorldPitchDeg(dx, dy, dz)
{
    local horiz = sqrt(dx * dx + dy * dy);
    return -SS2FA_RadToDeg(atan2(dz, horiz));
}

function SS2FA_DirToProxyFacingDarkMatrix(dx, dy, dz, headingBaselineValid, headingBaseline)
{
    local forward = SS2FA_NormalizeVec(vector(dx, dy, dz), vector(1.0, 0.0, 0.0));
    local worldUp = vector(0.0, 0.0, 1.0);
    local right = SS2FA_Cross(worldUp, forward);
    if(SS2FA_VecLen(right) <= 0.0001){
        right = vector(0.0, 1.0, 0.0);
    }
    right = SS2FA_ProjectOntoPlane(right, forward, vector(0.0, 1.0, 0.0));
    local up = SS2FA_NormalizeVec(SS2FA_Cross(forward, right), worldUp);

    local horiz = sqrt(forward.x * forward.x + forward.y * forward.y);
    local pitch = SS2FA_RadToDeg(atan2(-forward.z, horiz))
        + SS2FA_GetFloat("ss2fa_weapon_proxy_pitch_offset", 0.0);
    // The matang.c library uses atan2(y,x), but KEX's Object.Teleport facing
    // empirically uses the atan2(x,y) convention (proven by the working projectile
    // aim + the old proxy modes that pointed correctly). Default to the proven one;
    // keep the matang convention available behind a toggle for A/B testing.
    local darkHeading = SS2FA_GetInt("ss2fa_weapon_proxy_dark_heading", 0) != 0;
    local headingRaw = darkHeading
        ? SS2FA_DarkHeadingDeg(forward.x, forward.y)
        : SS2FA_WorldHeadingDeg(forward.x, forward.y);
    local heading = SS2FA_ApplyProxyHeadingMirror(headingRaw, headingBaselineValid, headingBaseline)
        + SS2FA_GetFloat("ss2fa_weapon_proxy_heading_offset", 0.0);
    local bank = SS2FA_RadToDeg(atan2(right.z, up.z))
        + SS2FA_GetFloat("ss2fa_weapon_proxy_bank_offset", 0.0);

    SS2FA.proxyRollRaw = bank;
    SS2FA.proxyRollApplied = bank;
    SS2FA.proxyRollSign = 1.0;
    SS2FA.proxyRollKill = 0;
    SS2FA.proxyDarkMatrix = 1;
    SS2FA.proxyBasisForward = forward;
    SS2FA.proxyBasisRight = right;
    SS2FA.proxyBasisUp = up;
    return vector(bank, pitch, heading);
}

// Mode 9: keep the gun upright relative to the VIEW (screen), not the world.
// bank=0 produces a world-upright gun (up = world-up). A screen/viewmodel gun must
// have up = the camera's up. The two coincide at horizon and when the crosshair is
// centred, and diverge off-centre at pitch -- which is exactly the observed roll
// (zero centred, grows with pitch, sign flips up/down). So bank = the signed
// world-up -> view-up roll about the barrel; it nulls the roll by construction.
function SS2FA_DirToProxyFacingViewUpright(dx, dy, dz)
{
    local forward = SS2FA_NormalizeVec(vector(dx, dy, dz), vector(1.0, 0.0, 0.0));
    local worldUp = vector(0.0, 0.0, 1.0);
    local viewUp = SS2FA_CameraWorldAxis(vector(0.0, 0.0, 1.0), worldUp);

    // Reference up that bank=0 yields (world-up in the plane across the barrel),
    // and the desired up (camera-up in that same plane).
    local upW = SS2FA_ProjectOntoPlane(worldUp, forward, worldUp);
    local upV = SS2FA_ProjectOntoPlane(viewUp, forward, upW);

    local horiz = sqrt(forward.x * forward.x + forward.y * forward.y);
    local pitch = SS2FA_RadToDeg(atan2(-forward.z, horiz))
        + SS2FA_GetFloat("ss2fa_weapon_proxy_pitch_offset", 0.0);
    local heading = SS2FA_WorldHeadingDeg(forward.x, forward.y)
        + SS2FA_GetFloat("ss2fa_weapon_proxy_heading_offset", 0.0);

    // Signed roll from upW to upV about the forward axis.
    local refRight = SS2FA_Cross(forward, upW);
    local cosB = SS2FA_Dot(upV, upW);
    local sinB = SS2FA_Dot(upV, refRight);
    local bank = SS2FA_RadToDeg(atan2(sinB, cosB))
            * SS2FA_GetFloat("ss2fa_weapon_proxy_view_up_sign", 1.0)
        + SS2FA_GetFloat("ss2fa_weapon_proxy_bank_offset", 0.0);

    SS2FA.proxyRollRaw = bank;
    SS2FA.proxyRollApplied = bank;
    SS2FA.proxyRollSign = SS2FA_GetFloat("ss2fa_weapon_proxy_view_up_sign", 1.0);
    SS2FA.proxyRollKill = 0;
    SS2FA.proxyBasisForward = forward;
    SS2FA.proxyBasisRight = refRight;
    SS2FA.proxyBasisUp = upV;
    return vector(bank, pitch, heading);
}

function SS2FA_DirFromHeadingPitchDeg(headingDeg, pitchDeg)
{
    local headingRad = headingDeg * SS2FA_PI / 180.0;
    local pitchRad = pitchDeg * SS2FA_PI / 180.0;
    local horiz = cos(pitchRad);
    return SS2FA_NormalizeVec(
        vector(sin(headingRad) * horiz, cos(headingRad) * horiz, -sin(pitchRad)),
        vector(0.0, 1.0, 0.0)
    );
}

function SS2FA_SignedAngleDeg(deg)
{
    while(deg > 180.0) deg -= 360.0;
    while(deg < -180.0) deg += 360.0;
    return deg;
}

function SS2FA_DarkToDeg(value)
{
    return SS2FA_SignedAngleDeg((value.tofloat() / 65535.0) * 360.0);
}

function SS2FA_ApplyProxyHeadingMirror(headingRaw, baselineValid, headingBaseline)
{
    local flipX = SS2FA_GetInt("ss2fa_weapon_proxy_flip_x", 0);
    local heading = headingRaw;
    if(flipX != 0 && baselineValid){
        local delta = SS2FA_SignedAngleDeg(headingRaw - headingBaseline);
        heading = SS2FA_SignedAngleDeg(headingBaseline - delta);
    }
    SS2FA.proxyHeadingRaw = headingRaw;
    SS2FA.proxyHeadingApplied = heading;
    SS2FA.proxyHeadingBase = baselineValid ? headingBaseline : 0.0;
    SS2FA.proxyHeadingFlipX = flipX;
    return heading;
}

function SS2FA_FormatVec(v)
{
    if(v == null) return "(null)";
    return "(" + format("%.3f", v.x) + "," + format("%.3f", v.y) + "," + format("%.3f", v.z) + ")";
}

function SS2FA_VecAddScale(origin, dir, scale)
{
    return vector(origin.x + dir.x * scale, origin.y + dir.y * scale, origin.z + dir.z * scale);
}

function SS2FA_FacingBasis(facing)
{
    local headingRad = SS2FA_DegToRad(facing.z);
    local pitchRad = SS2FA_DegToRad(facing.y);
    local bankRad = SS2FA_DegToRad(facing.x);
    local ch = cos(headingRad);
    local sh = sin(headingRad);
    local cp = cos(pitchRad);
    local sp = sin(pitchRad);
    local cb = cos(bankRad);
    local sb = sin(bankRad);

    local forward = SS2FA_NormalizeVec(vector(ch * cp, sh * cp, -sp), vector(1.0, 0.0, 0.0));
    local baseRight = vector(-sh, ch, 0.0);
    local baseUp = vector(ch * sp, sh * sp, cp);
    local right = SS2FA_NormalizeVec(
        vector(
            baseRight.x * cb + baseUp.x * sb,
            baseRight.y * cb + baseUp.y * sb,
            baseRight.z * cb + baseUp.z * sb
        ),
        vector(0.0, 1.0, 0.0)
    );
    local up = SS2FA_NormalizeVec(
        vector(
            baseUp.x * cb - baseRight.x * sb,
            baseUp.y * cb - baseRight.y * sb,
            baseUp.z * cb - baseRight.z * sb
        ),
        vector(0.0, 0.0, 1.0)
    );
    return { forward = forward, right = right, up = up };
}

function SS2FA_ResetProxyBasis()
{
    SS2FA.proxyBasisForward = null;
    SS2FA.proxyBasisRight = null;
    SS2FA.proxyBasisUp = null;
}

function SS2FA_StoredProxyBasis()
{
    try {
        if(SS2FA.proxyBasisForward != null
            && SS2FA.proxyBasisRight != null
            && SS2FA.proxyBasisUp != null
            && SS2FA_VecLen(SS2FA.proxyBasisForward) > 0.0001
            && SS2FA_VecLen(SS2FA.proxyBasisRight) > 0.0001
            && SS2FA_VecLen(SS2FA.proxyBasisUp) > 0.0001){
            return {
                forward = SS2FA_NormalizeVec(SS2FA.proxyBasisForward, vector(1.0, 0.0, 0.0)),
                right = SS2FA_NormalizeVec(SS2FA.proxyBasisRight, vector(0.0, 1.0, 0.0)),
                up = SS2FA_NormalizeVec(SS2FA.proxyBasisUp, vector(0.0, 0.0, 1.0))
            };
        }
    } catch(e) {}
    return null;
}

function SS2FA_ProxyBasisForFacing(facing)
{
    local basis = SS2FA_StoredProxyBasis();
    if(basis != null) return basis;
    return SS2FA_FacingBasis(facing);
}

function SS2FA_DrawProxyBasis(worldPos, basis)
{
    if(SS2FA_GetInt("ss2fa_weapon_proxy_axis_draw", 0) == 0) return;
    local len = SS2FA_GetFloat("ss2fa_weapon_proxy_axis_len", 1.25);
    if(len <= 0.0) len = 1.25;
    try {
        ShockOverlay.DrawWorldLine(worldPos, SS2FA_VecAddScale(worldPos, basis.forward, len));
        ShockOverlay.DrawWorldLine(worldPos, SS2FA_VecAddScale(worldPos, basis.right, len * 0.75));
        ShockOverlay.DrawWorldLine(worldPos, SS2FA_VecAddScale(worldPos, basis.up, len * 0.5));
    } catch(e) {
        if(!SS2FA.proxyAxisDrawFailureLogged){
            SS2FA.proxyAxisDrawFailureLogged = true;
            ::print("[SS2FA-PROXY] axis draw failed: " + e.tostring());
        }
    }
}

function SS2FA_ProxyEffectsActive()
{
    if(SS2FA_GetInt("ss2fa_enable", 1) == 0) return false;
    if(SS2FA_GetInt("ss2fa_weapon_follow_mode", 1) != 7) return false;
    if(SS2FA_GetInt("ss2fa_weapon_effect_follow", 1) == 0) return false;
    if(!("proxyValid" in SS2FA) || !SS2FA.proxyValid) return false;
    if(!("proxyWorldPos" in SS2FA) || SS2FA.proxyWorldPos == null) return false;
    if(!("proxyFacing" in SS2FA) || SS2FA.proxyFacing == null) return false;
    if(!("weaponProxyObj" in SS2FA) || SS2FA.weaponProxyObj == 0) return false;
    try {
        if(!Object.Exists(SS2FA.weaponProxyObj)) return false;
    } catch(e) {
        return false;
    }
    return true;
}

function SS2FA_CameraLocalFromWorld(worldPos)
{
    local origin = Camera.CameraToWorld(vector(0.0, 0.0, 0.0));
    local xAxis = SS2FA_CameraWorldAxis(vector(1.0, 0.0, 0.0), vector(1.0, 0.0, 0.0));
    local yAxis = SS2FA_CameraWorldAxis(vector(0.0, 1.0, 0.0), vector(0.0, 1.0, 0.0));
    local zAxis = SS2FA_CameraWorldAxis(vector(0.0, 0.0, 1.0), vector(0.0, 0.0, 1.0));
    local d = vector(worldPos.x - origin.x, worldPos.y - origin.y, worldPos.z - origin.z);
    return vector(SS2FA_Dot(d, xAxis), SS2FA_Dot(d, yAxis), SS2FA_Dot(d, zAxis));
}

function SS2FA_ProxyRigPointPose(pointRig, pointName)
{
    if(!SS2FA_ProxyEffectsActive()) return null;

    try {
        local gunPoint = pointRig.Get("gunPoint");
        local point = pointRig.Get(pointName);
        local gunPos = gunPoint.GetPos();
        local pointPos = point.GetPos();
        local localDelta = vector(
            (pointPos.x - gunPos.x) * SS2FA_GetFloat("ss2fa_weapon_effect_forward_sign", 1.0),
            (pointPos.y - gunPos.y) * SS2FA_GetFloat("ss2fa_weapon_effect_left_sign", 1.0),
            (pointPos.z - gunPos.z) * SS2FA_GetFloat("ss2fa_weapon_effect_up_sign", 1.0)
        );
        // Use the gun's TRUE rendered basis (engine facing->forward), not the stored
        // view-frame basis whose forward carries the ~180deg-off aim -- otherwise the
        // muzzle/eject points land mirrored horizontally off the visible proxy.
        local basis = SS2FA_FacingBasis(SS2FA.proxyFacing);
        local worldPos = vector(
            SS2FA.proxyWorldPos.x + basis.forward.x * localDelta.x - basis.right.x * localDelta.y + basis.up.x * localDelta.z,
            SS2FA.proxyWorldPos.y + basis.forward.y * localDelta.x - basis.right.y * localDelta.y + basis.up.y * localDelta.z,
            SS2FA.proxyWorldPos.z + basis.forward.z * localDelta.x - basis.right.z * localDelta.y + basis.up.z * localDelta.z
        );
        local bankDelta = SS2FA_SignedAngleDeg(SS2FA_DarkToDeg(point.GetBank()) - SS2FA_DarkToDeg(gunPoint.GetBank()));
        local pitchDelta = SS2FA_SignedAngleDeg(SS2FA_DarkToDeg(point.GetPitch()) - SS2FA_DarkToDeg(gunPoint.GetPitch()));
        local headingDelta = SS2FA_SignedAngleDeg(SS2FA_DarkToDeg(point.GetHeading()) - SS2FA_DarkToDeg(gunPoint.GetHeading()));
        local facing = vector(
            SS2FA_SignedAngleDeg(SS2FA.proxyFacing.x + bankDelta),
            SS2FA_SignedAngleDeg(SS2FA.proxyFacing.y + pitchDelta),
            SS2FA_SignedAngleDeg(SS2FA.proxyFacing.z + headingDelta)
        );
        return {
            world = worldPos,
            cameraLocal = SS2FA_CameraLocalFromWorld(worldPos),
            facing = facing,
            localDelta = localDelta
        };
    } catch(e) {
        if(!SS2FA.effectFailureLogged){
            SS2FA.effectFailureLogged = true;
            ::print("[SS2FA-FX] rig point transform failed point=" + pointName + " error=" + e.tostring());
        }
    }
    return null;
}

// Unit world dir -> Dark facing (heading, pitch, bank) degrees.
// Mirrors the SS2VR projectile redirect convention: positive pitch is down.
function SS2FA_DirToFacing(dx, dy, dz)
{
    local dir = SS2FA_NormalizeVec(vector(dx, dy, dz), vector(0.0, 1.0, 0.0));
    local heading = SS2FA_WorldHeadingDeg(dir.x, dir.y) + SS2FA_GetFloat("ss2fa_weapon_aim_heading_offset", 0.0);
    local pitch = SS2FA_WorldPitchDeg(dir.x, dir.y, dir.z) + SS2FA_GetFloat("ss2fa_weapon_aim_pitch_offset", 0.0);
    local bank = SS2FA_GetFloat("ss2fa_weapon_aim_bank_offset", 0.0);
    local mode = SS2FA_GetInt("ss2fa_weapon_aim_facing_mode", 0);
    if(mode == 1) return vector(0.0, pitch, heading);
    if(mode == 2) return vector(0.0, -pitch, heading + 90.0);
    if(mode == 3) return vector(heading, bank, pitch);
    return vector(heading, pitch, bank);
}

function SS2FA_DirToProjectileObjectFacing(dx, dy, dz, nativeFacing, preserveNativeBank)
{
    local dir = SS2FA_NormalizeVec(vector(dx, dy, dz), vector(0.0, 1.0, 0.0));
    // The bolt's visible long axis is the engine's facing->forward, which is the
    // SS2FA_FacingBasis convention (cos h*cp, sin h*cp, -sp) -- confirmed numerically against
    // the working gun and the (now-correct) pivot. So the facing whose forward == the flight
    // direction is heading = atan2(y, x) and pitch = WorldPitchDeg. IMPORTANT: this is NOT
    // SS2FA_WorldHeadingDeg, which is atan2(x, y) (measured from +Y) -- feeding that put the
    // heading on a 90deg-rotated axis and rendered the bolt sideways. Keep bank flat so an
    // axially-symmetric beam carries no spurious roll.
    local heading = SS2FA_RadToDeg(atan2(dir.y, dir.x))
        + SS2FA_GetFloat("ss2fa_projectile_heading_offset", 0.0);
    local pitch = SS2FA_WorldPitchDeg(dir.x, dir.y, dir.z) + SS2FA_GetFloat("ss2fa_projectile_pitch_offset", 0.0);
    local bank = SS2FA_GetFloat("ss2fa_projectile_bank_offset", 0.0);
    if(preserveNativeBank && nativeFacing != null){
        try { bank = nativeFacing.x; } catch(e) {}
    }
    // Object.Teleport world-object order is x=bank/roll, y=pitch, z=heading.
    return vector(SS2FA_SignedAngleDeg(bank), SS2FA_SignedAngleDeg(pitch), SS2FA_SignedAngleDeg(heading));
}

function SS2FA_DirToProxyFacing(dx, dy, dz)
{
    local dir = SS2FA_NormalizeVec(vector(dx, dy, dz), vector(0.0, 1.0, 0.0));
    local headingRaw = SS2FA_WorldHeadingDeg(dir.x, dir.y);
    local heading = headingRaw + SS2FA_GetFloat("ss2fa_weapon_proxy_heading_offset", 0.0);
    local pitch = SS2FA_WorldPitchDeg(dir.x, dir.y, dir.z) + SS2FA_GetFloat("ss2fa_weapon_proxy_pitch_offset", 0.0);
    local bank = SS2FA_GetFloat("ss2fa_weapon_proxy_bank_offset", 0.0);
    local mode = SS2FA_GetInt("ss2fa_weapon_proxy_facing_mode", 0);
    SS2FA.proxyRollRaw = 0.0;
    SS2FA.proxyRollApplied = 0.0;
    SS2FA.proxyRollSign = SS2FA_GetFloat("ss2fa_weapon_proxy_roll_sign", 1.0);
    SS2FA.proxyRollKill = 0;
    SS2FA.proxyHeadingRaw = headingRaw;
    SS2FA.proxyHeadingApplied = heading;
    SS2FA.proxyHeadingBase = 0.0;
    SS2FA.proxyHeadingFlipX = 0;
    SS2FA.proxyDarkMatrix = 0;
    // Object.Teleport/Position uses world-object order: x=roll, y=pitch, z=yaw.
    // CameraObj uses Heading/Pitch/Bank order, so keep the old order only as mode 1.
    if(mode == 1) return vector(heading, pitch, bank);
    if(mode == 2) return vector(bank, -pitch, heading);
    if(mode == 3) return vector(bank, pitch, heading + 90.0);
    if(mode == 5) return vector(bank, pitch, heading);
    if(mode == 4){
        local worldUp = vector(0.0, 0.0, 1.0);
        local cameraRight = SS2FA_CameraWorldAxis(vector(0.0, -1.0, 0.0), vector(1.0, 0.0, 0.0));
        local baseRight = SS2FA_ProjectOntoPlane(SS2FA_Cross(dir, worldUp), dir, cameraRight);
        local baseUp = SS2FA_NormalizeVec(SS2FA_Cross(baseRight, dir), worldUp);
        local cameraUp = SS2FA_CameraWorldAxis(vector(0.0, 0.0, 1.0), baseUp);
        local wantedUp = SS2FA_ProjectOntoPlane(cameraUp, dir, baseUp);
        local roll = SS2FA_RadToDeg(atan2(SS2FA_Dot(wantedUp, baseRight), SS2FA_Dot(wantedUp, baseUp)));
        local rollSign = SS2FA_GetFloat("ss2fa_weapon_proxy_roll_sign", 1.0);
        SS2FA.proxyRollRaw = roll;
        SS2FA.proxyRollApplied = roll * rollSign;
        SS2FA.proxyRollSign = rollSign;
        SS2FA.proxyRollKill = 0;
        bank += SS2FA.proxyRollApplied;
        return vector(bank, pitch, heading);
    }
    return vector(bank, pitch, heading);
}

function SS2FA_GetProjVel(obj)
{
    try { if(Property.Possessed(obj, "PhysState")) return Property.Get(obj, "PhysState", "Velocity"); } catch(e) {}
    try { if(Property.Possessed(obj, "PhysControl")) return Property.Get(obj, "PhysControl", "Velocity"); } catch(e) {}
    try { if(Property.Possessed(obj, "PhysControl")) return Property.Get(obj, "PhysControl", "AxisVelocity"); } catch(e) {}
    return vector(0, 0, 0);
}

function SS2FA_SetProjVel(obj, vel)
{
    local mode = SS2FA_GetInt("ss2fa_aim_velocity_mode", 7);
    local wrote = 0;
    try { if((mode & 1) != 0) { Physics.SetVelocity(obj, vel); wrote = wrote + 1; } } catch(e) {}
    try { if((mode & 2) != 0 && Property.Possessed(obj, "PhysState"))   { Property.Set(obj, "PhysState", "Velocity", vel);   wrote = wrote + 2; } } catch(e) {}
    try { if((mode & 4) != 0 && Property.Possessed(obj, "PhysControl")) { Property.Set(obj, "PhysControl", "Velocity", vel); wrote = wrote + 4; } } catch(e) {}
    try { if((mode & 8) != 0 && Property.Possessed(obj, "PhysControl")) { Property.Set(obj, "PhysControl", "AxisVelocity", vel); wrote = wrote + 8; } } catch(e) {}
    return wrote;
}

//----------------------------------------------------------------------------
//  Semantic world selection (ported from the working SS2VR left-hand frob path)
//----------------------------------------------------------------------------
function SS2FA_ObjName(obj)
{
    try { if(Object.Exists(obj)) return Object.GetName(obj); } catch(e) {}
    return "<none>";
}

function SS2FA_ArchName(obj)
{
    try {
        if(Object.Exists(obj)){
            local archetype = Object.Archetype(obj);
            if(Object.Exists(archetype)) return Object.GetName(archetype);
        }
    } catch(e) {}
    return "<none>";
}

function SS2FA_HasFrobInfo(obj)
{
    try { return Object.Exists(obj) && Property.Possessed(obj, "FrobInfo"); } catch(e) {}
    return false;
}

function SS2FA_Blocked(obj)
{
    try {
        if(Object.Exists(obj) && Property.Possessed(obj, "BlockFrob"))
            return Property.Get(obj, "BlockFrob", "") != 0;
    } catch(e) {}
    return false;
}

function SS2FA_FrobActionBits(obj)
{
    if(!SS2FA_HasFrobInfo(obj)) return 0;
    local bits = 0;
    try { bits = bits | Property.Get(obj, "FrobInfo", "World Action").tointeger(); } catch(e1) {}
    try { bits = bits | Property.Get(obj, "FrobInfo", "Inv Action").tointeger(); } catch(e2) {}
    try { bits = bits | Property.Get(obj, "FrobInfo", "Tool Action").tointeger(); } catch(e3) {}
    return bits;
}

function SS2FA_FrobInfoText(obj)
{
    if(!SS2FA_HasFrobInfo(obj)) return "no_frobinfo";
    try {
        return "world=" + Property.Get(obj, "FrobInfo", "World Action")
            + " inv=" + Property.Get(obj, "FrobInfo", "Inv Action")
            + " tool=" + Property.Get(obj, "FrobInfo", "Tool Action");
    } catch(e) {
        return "frobinfo_read_failed";
    }
}

function SS2FA_TextContains(text, needles)
{
    local lowered = text.tolower();
    foreach(needle in needles){
        if(lowered.find(needle) != null) return true;
    }
    return false;
}

function SS2FA_NameBlob(obj) { return SS2FA_ObjName(obj) + " " + SS2FA_ArchName(obj); }

function SS2FA_WeaponNameFromHandler(wh)
{
    try {
        if(wh != null && ("m_equippedWeapon" in wh) && Object.Exists(wh.m_equippedWeapon)){
            return SS2FA_NameBlob(wh.m_equippedWeapon);
        }
    } catch(e) {}
    return "";
}

function SS2FA_IsMeleeEquipped(wh)
{
    try {
        if(wh != null
            && ("m_equippedWeapon" in wh)
            && Object.Exists(wh.m_equippedWeapon)
            && Property.Possessed(wh.m_equippedWeapon, "InvLimbModel")){
            return true;
        }
    } catch(e) {}
    return false;
}

function SS2FA_IsLongProxyWeapon(weaponName, model)
{
    return SS2FA_TextContains(weaponName + " " + model,
        ["shotgun", "assault", "rifle", "emp", "grenade", "launcher", "fusion", "cannon"]);
}

function SS2FA_ProxyLocalToWorldOffset(localOffset, basis)
{
    return vector(
        basis.forward.x * localOffset.x - basis.right.x * localOffset.y + basis.up.x * localOffset.z,
        basis.forward.y * localOffset.x - basis.right.y * localOffset.y + basis.up.y * localOffset.z,
        basis.forward.z * localOffset.x - basis.right.z * localOffset.y + basis.up.z * localOffset.z
    );
}

function SS2FA_PointLocalToWorldOffset(localOffset)
{
    local rot = vector(0.0, 0.0, 0.0);
    try { rot = Camera.GetFacing(); } catch(e) {}

    // Match ND.Point.Rotate(): local X/Y/Z are rotated by parent X, then Y, then Z.
    // Melee PlyrArm is driven from an armPoint under cameraPoint, not the gun proxy
    // offset convention. Live Wrench testing shows local X is depth/forward, local Y
    // is lateral, and local Z is vertical.
    local x = localOffset.x;
    local y = localOffset.y;
    local z = localOffset.z;

    local angleX = rot.x * SS2FA_PI / 180.0;
    local angleY = rot.y * SS2FA_PI / 180.0;
    local angleZ = rot.z * SS2FA_PI / 180.0;

    local newX = x;
    local newY = y * cos(angleX) - z * sin(angleX);
    local newZ = y * sin(angleX) + z * cos(angleX);
    x = newX; y = newY; z = newZ;

    newX = x * cos(angleY) + z * sin(angleY);
    newY = y;
    newZ = -x * sin(angleY) + z * cos(angleY);
    x = newX; y = newY; z = newZ;

    return vector(
        x * cos(angleZ) - y * sin(angleZ),
        x * sin(angleZ) + y * cos(angleZ),
        z
    );
}

function SS2FA_IsAcceptReason(reason)
{
    return reason != null && reason.len() >= 6 && reason.slice(0, 6) == "accept";
}

function SS2FA_IsContainedObject(obj)
{
    try {
        local containsKind = LinkTools.LinkKindNamed("Contains");
        foreach(l in Link.GetAll(containsKind, 0, obj)){
            local link = sLink(l);
            if(link.dest == obj && link.source > 0) return true;
        }
    } catch(e) {}
    return false;
}

function SS2FA_SelectionReason(obj, requireSemantic)
{
    try {
        if(!Object.Exists(obj)) return "reject_missing";
    } catch(e) {
        return "reject_exception";
    }
    if(("weaponProxyObj" in SS2FA) && SS2FA.weaponProxyObj != 0 && obj == SS2FA.weaponProxyObj)
        return "reject_freelook_weapon_proxy";
    if(SS2FA_IsContainedObject(obj)) return "reject_contained";
    if(SS2FA_Blocked(obj)) return "reject_blockfrob";
    local blob = SS2FA_NameBlob(obj);
    if(SS2FA_TextContains(blob, [
        "sound", "ambient", "light", "decal", "fx_", "particle", "marker", "vhot",
        "window", "chair", "table", "desk"
    ])) return "reject_name_noise";
    if(SS2FA_FrobActionBits(obj) != 0) return "accept_frobinfo_action";
    if(SS2FA_TextContains(blob, [
        "switch", "button", "keypad", "reader", "slot", "card", "key", "corpse",
        "body", "weapon", "pistol", "ammo", "hypo", "log", "door", "container",
        "crate", "pickup"
    ])) return "accept_name_hint";
    return requireSemantic ? "reject_not_semantic" : "accept_permissive";
}

function SS2FA_RayProbeScore(aim, obj, reach, radius, requireSemantic)
{
    local reason = SS2FA_SelectionReason(obj, requireSemantic);

    local pos = null;
    try { pos = Object.Position(obj); } catch(e) { return null; }

    local vx = pos.x - aim.wox;
    local vy = pos.y - aim.woy;
    local vz = pos.z - aim.woz;
    local along = vx * aim.wdx + vy * aim.wdy + vz * aim.wdz;
    local cx = aim.wox + aim.wdx * along;
    local cy = aim.woy + aim.wdy * along;
    local cz = aim.woz + aim.wdz * along;
    local dx = pos.x - cx;
    local dy = pos.y - cy;
    local dz = pos.z - cz;
    local dist = sqrt(dx * dx + dy * dy + dz * dz);

    local accepted = SS2FA_IsAcceptReason(reason);
    if(along < 0.0){
        accepted = false;
        reason = "reject_behind:" + reason;
    } else if(along > reach){
        accepted = false;
        reason = "reject_reach:" + reason;
    } else if(dist > radius){
        accepted = false;
        reason = "reject_radius:" + reason;
    }

    return {
        obj = obj,
        dist = dist,
        along = along,
        score = dist + (along < 0.0 ? -along * 0.50 : 0.0) + (along > reach ? (along - reach) * 0.10 : 0.0),
        reason = reason,
        accepted = accepted
    };
}

function SS2FA_RayScore(aim, obj, reach, radius, requireSemantic)
{
    local reason = SS2FA_SelectionReason(obj, requireSemantic);
    if(!SS2FA_IsAcceptReason(reason)) return null;

    local pos = null;
    try { pos = Object.Position(obj); } catch(e) { return null; }

    local vx = pos.x - aim.wox;
    local vy = pos.y - aim.woy;
    local vz = pos.z - aim.woz;
    local along = vx * aim.wdx + vy * aim.wdy + vz * aim.wdz;
    if(along < 0.0 || along > reach) return null;

    local cx = aim.wox + aim.wdx * along;
    local cy = aim.woy + aim.wdy * along;
    local cz = aim.woz + aim.wdz * along;
    local dx = pos.x - cx;
    local dy = pos.y - cy;
    local dz = pos.z - cz;
    local dist = sqrt(dx * dx + dy * dy + dz * dz);
    if(dist > radius) return null;

    return {
        obj = obj,
        dist = dist,
        along = along,
        score = dist + along * 0.015,
        reason = reason
    };
}

function SS2FA_PushTop(top, entry, maxTop)
{
    if(maxTop <= 0) return;
    local inserted = false;
    for(local i = 0; i < top.len(); i++){
        if(entry.score < top[i].score){
            top.insert(i, entry);
            inserted = true;
            break;
        }
    }
    if(!inserted) top.append(entry);
    while(top.len() > maxTop) top.pop();
}

function SS2FA_TopSummary(top)
{
    local s = "";
    for(local i = 0; i < top.len(); i++){
        local e = top[i];
        if(i > 0) s += " | ";
        s += "#" + i + " obj=" + e.obj
            + " d=" + format("%.2f", e.dist)
            + " a=" + format("%.2f", e.along)
            + (("screenDist" in e) ? (" sd=" + format("%.1f", e.screenDist)
                + " screen=(" + e.sx + "," + e.sy + ")"
                + " reticle=(" + format("%.1f", e.rx) + "," + format("%.1f", e.ry) + ")") : "")
            + " " + SS2FA_ObjName(e.obj)
            + "/" + SS2FA_ArchName(e.obj)
            + " " + e.reason;
    }
    return s;
}

function SS2FA_ScanRay(aim)
{
    local reach = SS2FA_GetFloat("ss2fa_selection_semantic_reach", 8.0);
    local radius = SS2FA_GetFloat("ss2fa_selection_semantic_radius", 1.8);
    local maxObj = SS2FA_GetInt("ss2fa_selection_semantic_max_obj", 10000);
    local logTop = SS2FA_GetInt("ss2fa_selection_semantic_log_top", 5);
    local requireSemantic = SS2FA_GetInt("ss2fa_selection_semantic_require", 1) != 0;
    local probeRejected = SS2FA_GetInt("ss2fa_selection_semantic_probe_rejected", 1) != 0;
    local probeMargin = SS2FA_GetFloat("ss2fa_selection_semantic_probe_margin", 4.0);
    local top = [];
    local rejectTop = [];
    local scanned = 0;
    local considered = 0;
    local rejected = 0;
    local best = null;

    for(local obj = 1; obj <= maxObj; obj++){
        local exists = false;
        try { exists = Object.Exists(obj); } catch(e0) { exists = false; }
        if(!exists) continue;
        scanned++;
        local entry = SS2FA_RayProbeScore(aim, obj, reach, radius, requireSemantic);
        if(entry == null) continue;
        if(!entry.accepted){
            rejected++;
            if(probeRejected && entry.along >= -probeMargin && entry.along <= reach + probeMargin)
                SS2FA_PushTop(rejectTop, entry, logTop);
            continue;
        }
        considered++;
        if(best == null || entry.score < best.score) best = entry;
        SS2FA_PushTop(top, entry, logTop);
    }

    return {
        mode = "ray",
        target = best != null ? best.obj : 0,
        best = best,
        top = top,
        rejectTop = rejectTop,
        scanned = scanned,
        considered = considered,
        rejected = rejected,
        reach = reach,
        radius = radius,
        requireSemantic = requireSemantic
    };
}

function SS2FA_PublishSelectionTarget(target)
{
    try { Debug.Command("set", "ss2fa_hl " + target); } catch(e) {}
}

function SS2FA_PublishCanvasInfo(force)
{
    local canvas = SS2FA_CanvasInfo();
    if(force || canvas.rawX != SS2FA.lastCanvasRawX || canvas.rawY != SS2FA.lastCanvasRawY){
        SS2FA.lastCanvasRawX = canvas.rawX;
        SS2FA.lastCanvasRawY = canvas.rawY;
        try { Debug.Command("set", "ss2fa_canvas " + canvas.rawX + " " + canvas.rawY); } catch(e) {}
    }
}

function SS2FA_PublishAlive()
{
    try { Debug.Command("set", "ss2fa_alive 1"); } catch(e) {}
    SS2FA_PublishCanvasInfo(false);
}

function SS2FA_GameplayHudMode()
{
    try { if(ShockGame.MouseCursor()) return false; } catch(e) {}
    try { if(Quest.Get("HideInterface")) return false; } catch(e) {}
    return true;
}

// Measure the engine's REAL ShockOverlay space. In Freelook the camera does not move (only the
// cursor does), so a point along the camera forward axis always sits at the visual screen
// centre. ShockOverlay.WorldToScreen of that point therefore returns the overlay coordinates of
// the centre -> overlay dimensions = 2x that, at ANY resolution. This replaces two competing
// ASSUMPTIONS that each failed somewhere: fixed 960x540 (decision log) vs height-normalized
// width (rawW*540/rawH). Two consistent samples required; recalibrates when the raw canvas
// changes. Kill switch: ss2fa_overlay_calibrate=0 falls back to the height-normalized model.
function SS2FA_CalibrateOverlaySpace()
{
    if(SS2FA_GetInt("ss2fa_overlay_calibrate", 1) == 0) return;
    try {
        local width = int_ref();
        local height = int_ref();
        Engine.GetCanvasSize(width, height);
        local rawW = width.tointeger();
        local rawH = height.tointeger();
        if(rawW <= 0 || rawH <= 0) return;
        if(SS2FA.overlayCalValid && SS2FA.overlayCalRawX == rawW && SS2FA.overlayCalRawY == rawH)
            return;
        if(SS2FA.overlayCalRawX != rawW || SS2FA.overlayCalRawY != rawH){
            SS2FA.overlayCalValid = false;
            SS2FA.overlayCalSampleX = -1;
            SS2FA.overlayCalSampleY = -1;
            SS2FA.overlayCalLogged = false;
            SS2FA.overlayCalRawX = rawW;
            SS2FA.overlayCalRawY = rawH;
        }

        local facing = Camera.GetFacing(); // (x=bank, y=pitch, z=heading) -- proven convention
        local basis = SS2FA_FacingBasis(facing);
        local origin = Camera.CameraToWorld(vector(0.0, 0.0, 0.0));
        local point = vector(
            origin.x + basis.forward.x * 64.0,
            origin.y + basis.forward.y * 64.0,
            origin.z + basis.forward.z * 64.0
        );
        local sxRef = int_ref();
        local syRef = int_ref();
        ShockOverlay.WorldToScreen(point, sxRef, syRef);
        local sx = sxRef.tointeger();
        local sy = syRef.tointeger();
        // (0,0) is the offscreen sentinel; sanity-bound the centre to plausible overlay sizes.
        if(sx < 64 || sx > 8192 || sy < 36 || sy > 8192) return;

        if(SS2FA.overlayCalSampleX < 0){
            SS2FA.overlayCalSampleX = sx;
            SS2FA.overlayCalSampleY = sy;
            return;
        }
        local dx = sx - SS2FA.overlayCalSampleX;
        local dy = sy - SS2FA.overlayCalSampleY;
        if(dx < -2 || dx > 2 || dy < -2 || dy > 2){
            // unstable (camera moving between samples) - restart with the fresh sample
            SS2FA.overlayCalSampleX = sx;
            SS2FA.overlayCalSampleY = sy;
            return;
        }
        SS2FA.overlayCalW = (SS2FA.overlayCalSampleX + sx).tofloat();
        SS2FA.overlayCalH = (SS2FA.overlayCalSampleY + sy).tofloat();
        SS2FA.overlayCalValid = true;
        if(!SS2FA.overlayCalLogged){
            SS2FA.overlayCalLogged = true;
            local modelW = rawW.tofloat() * 540.0 / rawH.tofloat();
            ::print("[SS2FA-XHAIR-CAL] worldToScreenCenter=(" + sx + "," + sy + ")"
                + " measuredOverlay=(" + format("%.0f", SS2FA.overlayCalW) + "x" + format("%.0f", SS2FA.overlayCalH) + ")"
                + " heightNormModel=(" + format("%.0f", modelW) + "x540)"
                + " fixedModel=(960x540)"
                + " rawCanvas=" + rawW + "x" + rawH);
        }
    } catch(e) {}
}

function SS2FA_CanvasInfo()
{
    try {
        local width = int_ref();
        local height = int_ref();
        Engine.GetCanvasSize(width, height);
        local rawW = width.tointeger();
        local rawH = height.tointeger();
        if(rawW > 0 && rawH > 0) {
            // Prefer the MEASURED overlay space (WorldToScreen calibration). Fallback model:
            // height-normalized virtual UI space (hudH=540, X expands with aspect).
            if(SS2FA.overlayCalValid && SS2FA.overlayCalRawX == rawW && SS2FA.overlayCalRawY == rawH){
                return { rawX = rawW, rawY = rawH, hudX = SS2FA.overlayCalW, hudY = SS2FA.overlayCalH };
            }
            local hudH = 540.0;
            local hudW = rawW.tofloat() * hudH / rawH.tofloat();
            return { rawX = rawW, rawY = rawH, hudX = hudW, hudY = hudH };
        }
    } catch(e) {}
    return { rawX = 1920, rawY = 1080, hudX = 960, hudY = 540 };
}

function SS2FA_CanvasSize()
{
    local info = SS2FA_CanvasInfo();
    return { x = info.hudX, y = info.hudY };
}

function SS2FA_OverlayOriginBiasScale()
{
    return SS2FA_GetFloat("ss2fa_native_hud_origin_bias_scale", 0.0);
}

function SS2FA_ProjectAimToOverlay(aim)
{
    if(SS2FA_GetInt("ss2fa_native_hud_reticle_world_projection", 0) == 0)
        return null;
    try {
        local dist = SS2FA_GetFloat("ss2fa_native_hud_reticle_project_distance", 64.0);
        if(dist < 1.0) dist = 1.0;
        local pos = vector(
            aim.wox + aim.wdx * dist,
            aim.woy + aim.wdy * dist,
            aim.woz + aim.wdz * dist
        );
        local x = int_ref();
        local y = int_ref();
        ShockOverlay.WorldToScreen(pos, x, y);
        local sx = x.tointeger();
        local sy = y.tointeger();
        if(sx == 0 && sy == 0) return null;
        return {
            x = sx.tofloat(),
            y = sy.tofloat(),
            dist = dist,
            pos = pos
        };
    } catch(e) {}
    return null;
}

function SS2FA_ReticleOverlayPoint(aim)
{
    local canvas = SS2FA_CanvasInfo();
    local targetMinusOneX = aim.cu * (canvas.hudX - 1);
    local targetMinusOneY = aim.cv * (canvas.hudY - 1);
    local targetOverlayX = targetMinusOneX;
    local targetOverlayY = targetMinusOneY;
    local originBiasScale = SS2FA_OverlayOriginBiasScale();
    local originBiasX = (canvas.hudX / 16.0) * originBiasScale;
    local originBiasY = (canvas.hudY / 16.0) * originBiasScale;
    local source = "canvas";
    local projected = SS2FA_ProjectAimToOverlay(aim);
    local projectDist = 0.0;
    local projectPos = null;
    local x = targetOverlayX;
    local y = targetOverlayY;

    if(projected != null){
        x = projected.x;
        y = projected.y;
        projectDist = projected.dist;
        projectPos = projected.pos;
        source = "world";
        originBiasX = 0.0;
        originBiasY = 0.0;
    } else if(SS2FA_GetInt("ss2fa_selection_screen_use_reticle_bias", 1) != 0){
        x -= originBiasX;
        y -= originBiasY;
    }
    x += SS2FA_GetFloat("ss2fa_native_hud_reticle_offset_x", 0.0);
    y += SS2FA_GetFloat("ss2fa_native_hud_reticle_offset_y", 0.0);
    return {
        x = x,
        y = y,
        originBiasX = originBiasX,
        originBiasY = originBiasY,
        rawX = canvas.rawX,
        rawY = canvas.rawY,
        hudX = canvas.hudX,
        hudY = canvas.hudY,
        targetMinusOneX = targetMinusOneX,
        targetMinusOneY = targetMinusOneY,
        targetOverlayX = targetOverlayX,
        targetOverlayY = targetOverlayY,
        source = source,
        projectDist = projectDist,
        projectPos = projectPos
    };
}

function SS2FA_ProjectObjScreen(obj)
{
    try {
        local pos = Object.Position(obj);
        local x = int_ref();
        local y = int_ref();
        ShockOverlay.WorldToScreen(pos, x, y);
        local sx = x.tointeger();
        local sy = y.tointeger();
        if(sx == 0 && sy == 0) return null;
        return { x = sx, y = sy, pos = pos };
    } catch(e) {}
    return null;
}

function SS2FA_ScreenProbeScore(aim, obj, reticle, reach, radiusPx, requireSemantic, requireRendered)
{
    local reason = SS2FA_SelectionReason(obj, requireSemantic);
    local accepted = SS2FA_IsAcceptReason(reason);

    if(requireRendered){
        try {
            if(!Object.RenderedThisFrame(obj)){
                accepted = false;
                reason = "reject_not_rendered:" + reason;
            }
        } catch(e) {}
    }

    local screen = SS2FA_ProjectObjScreen(obj);
    if(screen == null) return null;

    local vx = screen.pos.x - aim.wox;
    local vy = screen.pos.y - aim.woy;
    local vz = screen.pos.z - aim.woz;
    local along = vx * aim.wdx + vy * aim.wdy + vz * aim.wdz;
    local cameraDist = sqrt(vx * vx + vy * vy + vz * vz);
    local dx = screen.x - reticle.x;
    local dy = screen.y - reticle.y;
    local screenDist = sqrt(dx * dx + dy * dy);

    if(along < 0.0){
        accepted = false;
        reason = "reject_behind:" + reason;
    } else if(cameraDist > reach){
        accepted = false;
        reason = "reject_reachdist:" + reason;
    } else if(screenDist > radiusPx){
        accepted = false;
        reason = "reject_screen:" + reason;
    }

    return {
        obj = obj,
        dist = screenDist,
        screenDist = screenDist,
        along = along,
        cameraDist = cameraDist,
        score = screenDist + cameraDist * 0.10,
        reason = reason,
        accepted = accepted,
        sx = screen.x,
        sy = screen.y,
        rx = reticle.x,
        ry = reticle.y
    };
}

function SS2FA_ScanScreen(aim)
{
    local reach = SS2FA_GetFloat("ss2fa_selection_semantic_reach", 8.0);
    local radiusPx = SS2FA_GetFloat("ss2fa_selection_screen_radius_px", 64.0);
    local probeMarginPx = SS2FA_GetFloat("ss2fa_selection_screen_probe_margin_px", 96.0);
    local maxObj = SS2FA_GetInt("ss2fa_selection_semantic_max_obj", 10000);
    local logTop = SS2FA_GetInt("ss2fa_selection_semantic_log_top", 5);
    local requireSemantic = SS2FA_GetInt("ss2fa_selection_semantic_require", 1) != 0;
    local requireRendered = SS2FA_GetInt("ss2fa_selection_screen_require_rendered", 0) != 0;
    local probeRejected = SS2FA_GetInt("ss2fa_selection_semantic_probe_rejected", 1) != 0;
    local reticle = SS2FA_ReticleOverlayPoint(aim);
    local top = [];
    local rejectTop = [];
    local scanned = 0;
    local considered = 0;
    local rejected = 0;
    local best = null;

    for(local obj = 1; obj <= maxObj; obj++){
        local exists = false;
        try { exists = Object.Exists(obj); } catch(e0) { exists = false; }
        if(!exists) continue;
        scanned++;
        local entry = SS2FA_ScreenProbeScore(aim, obj, reticle, reach, radiusPx, requireSemantic, requireRendered);
        if(entry == null) continue;
        if(!entry.accepted){
            rejected++;
            if(probeRejected && entry.screenDist <= radiusPx + probeMarginPx)
                SS2FA_PushTop(rejectTop, entry, logTop);
            continue;
        }
        considered++;
        if(best == null || entry.score < best.score) best = entry;
        SS2FA_PushTop(top, entry, logTop);
    }

    return {
        mode = "screen",
        target = best != null ? best.obj : 0,
        best = best,
        top = top,
        rejectTop = rejectTop,
        scanned = scanned,
        considered = considered,
        rejected = rejected,
        reach = reach,
        radius = radiusPx,
        requireSemantic = requireSemantic,
        reticle = reticle
    };
}

function SS2FA_ScanSelection(aim)
{
    local mode = SS2FA_GetInt("ss2fa_selection_semantic_mode", 1);
    if(mode == 2) return SS2FA_ScanScreen(aim);
    return SS2FA_ScanRay(aim);
}

class SS2FA.SelectionHandler
{
    m_name = "SS2FA_SelectionHandler";
    m_loggedActive = false;
    m_lastTarget = 0;
    m_lastLogTime = 0;
    m_lastScanTime = 0;
    m_lastPublishTime = 0;
    m_lastScan = null;
    m_markerBitmap = null;
    m_markerBitmapName = "";
    m_markerBitmapW = 16;
    m_markerBitmapH = 16;
    m_markerFailureLogged = false;
    m_markerProjectionFailureLogged = false;
    m_markerLastLogTime = 0;
    m_markerLastTarget = 0;
    m_bracketBitmaps = null;
    m_bracketBitmapNames = null;
    m_bracketBitmapW = null;
    m_bracketBitmapH = null;
    m_bracketFailureLogged = false;

    function ClearTarget()
    {
        if(m_lastTarget != 0){
            m_lastTarget = 0;
            SS2FA_PublishSelectionTarget(0);
            m_lastPublishTime = ShockGame.SimTime();
            m_markerLastTarget = 0;
            if(SS2FA_GetInt("ss2fa_selection_semantic_log", 0) != 0)
                ::print("[SS2FA-SEL] target cleared");
        }
    }

    function Init()
    {
        if(SS2FA_GetInt("ss2fa_selection_semantic_log", 0) != 0)
            ::print("[SS2FA-SEL] SelectionHandler init");
    }

    function ResolveMarkerBitmap()
    {
        if(m_markerBitmap != null) return true;

        foreach(name in ["ND-icn_hover", "crosshai", "CROSSHAI"]){
            try {
                local bitmap = ShockOverlay.GetBitmap(name);
                local width = int_ref();
                local height = int_ref();
                ShockOverlay.GetBitmapSize(bitmap, width, height);
                m_markerBitmap = bitmap;
                m_markerBitmapName = name;
                m_markerBitmapW = width.tointeger();
                m_markerBitmapH = height.tointeger();
                if(m_markerBitmapW <= 0) m_markerBitmapW = 16;
                if(m_markerBitmapH <= 0) m_markerBitmapH = 16;
                return true;
            } catch(e) {}
        }

        if(!m_markerFailureLogged){
            m_markerFailureLogged = true;
            ::print("[SS2FA-SELDBG] marker bitmap lookup failed");
        }
        return false;
    }

    function ResolveBracketBitmaps()
    {
        if(m_bracketBitmaps != null) return true;

        local names = ["BRACK0", "BRACK1", "BRACK2", "BRACK3"];
        local bitmaps = [];
        local widths = [];
        local heights = [];
        foreach(name in names){
            try {
                local bitmap = ShockOverlay.GetBitmap(name);
                local width = int_ref();
                local height = int_ref();
                ShockOverlay.GetBitmapSize(bitmap, width, height);
                bitmaps.append(bitmap);
                widths.append(width.tointeger() > 0 ? width.tointeger() : 10);
                heights.append(height.tointeger() > 0 ? height.tointeger() : 10);
            } catch(e) {
                if(!m_bracketFailureLogged){
                    m_bracketFailureLogged = true;
                    ::print("[SS2FA-SELDBG] stock bracket bitmap lookup failed at " + name + ": " + e.tostring());
                }
                return false;
            }
        }

        m_bracketBitmaps = bitmaps;
        m_bracketBitmapNames = names;
        m_bracketBitmapW = widths;
        m_bracketBitmapH = heights;
        return true;
    }

    function ProjectTargetToScreen(target)
    {
        try {
            local pos = Object.Position(target);
            local x = int_ref();
            local y = int_ref();
            ShockOverlay.WorldToScreen(pos, x, y);
            local sx = x.tointeger();
            local sy = y.tointeger();
            if(sx == 0 && sy == 0) return null;
            return { x = sx, y = sy, pos = pos };
        } catch(e) {
            if(!m_markerProjectionFailureLogged){
                m_markerProjectionFailureLogged = true;
                ::print("[SS2FA-SELDBG] WorldToScreen failed: " + e.tostring());
            }
        }
        return null;
    }

    function DrawLegacyMarker(screen)
    {
        if(!ResolveMarkerBitmap()) return;

        local drawX = screen.x - (m_markerBitmapW / 2);
        local drawY = screen.y - (m_markerBitmapH / 2);
        ShockOverlay.DrawBitmap(m_markerBitmap, drawX, drawY);
        ShockOverlay.DrawString("[", screen.x - 18, screen.y - 8);
        ShockOverlay.DrawString("]", screen.x + 12, screen.y - 8);
    }

    function DrawNativeBracketMarker(screen)
    {
        if(!ResolveBracketBitmaps()) return false;

        local halfW = SS2FA_GetInt("ss2fa_selection_debug_marker_half_w_px", 48);
        local halfH = SS2FA_GetInt("ss2fa_selection_debug_marker_half_h_px", 32);
        if(halfW < 8) halfW = 8;
        if(halfH < 8) halfH = 8;
        if(halfW > 256) halfW = 256;
        if(halfH > 256) halfH = 256;

        local left = screen.x - halfW;
        local right = screen.x + halfW;
        local top = screen.y - halfH;
        local bottom = screen.y + halfH;

        ShockOverlay.DrawBitmap(m_bracketBitmaps[0], left, top);
        ShockOverlay.DrawBitmap(m_bracketBitmaps[1], right - m_bracketBitmapW[1], top);
        ShockOverlay.DrawBitmap(m_bracketBitmaps[2], right - m_bracketBitmapW[2], bottom - m_bracketBitmapH[2]);
        ShockOverlay.DrawBitmap(m_bracketBitmaps[3], left, bottom - m_bracketBitmapH[3]);
        return true;
    }

    function DrawDebugMarker(target, scan)
    {
        if(SS2FA_GetInt("ss2fa_selection_debug_marker", 1) == 0) return;
        if(target <= 0) return;
        if(!SS2FA_GameplayHudMode()) return;

        local screen = ProjectTargetToScreen(target);
        if(screen == null) return;
        local style = SS2FA_GetInt("ss2fa_selection_debug_marker_style", 2);
        local drewNative = false;

        try {
            if(style == 2) drewNative = DrawNativeBracketMarker(screen);
            if(!drewNative) DrawLegacyMarker(screen);
        } catch(e) {
            if(!m_markerFailureLogged){
                m_markerFailureLogged = true;
                ::print("[SS2FA-SELDBG] marker draw failed: " + e.tostring());
            }
            return;
        }

        if(SS2FA_GetInt("ss2fa_selection_debug_marker_log", 0) == 0) return;
        local now = ShockGame.SimTime();
        if(target == m_markerLastTarget && now - m_markerLastLogTime < 1000) return;
        m_markerLastLogTime = now;
        m_markerLastTarget = target;
        local best = (scan != null) ? scan.best : null;
        local reticle = (scan != null && ("reticle" in scan)) ? scan.reticle : null;
        local deltaText = "";
        if(reticle != null){
            deltaText = " reticle=(" + format("%.1f", reticle.x) + "," + format("%.1f", reticle.y) + ")"
                + " delta=(" + format("%.1f", screen.x - reticle.x) + "," + format("%.1f", screen.y - reticle.y) + ")";
        }
        ::print("[SS2FA-SELDBG] marker target=" + target
            + " mode=" + ((scan != null && ("mode" in scan)) ? scan.mode : "?")
            + " screen=(" + screen.x + "," + screen.y + ")"
            + deltaText
            + " world=(" + format("%.2f", screen.pos.x) + "," + format("%.2f", screen.pos.y) + "," + format("%.2f", screen.pos.z) + ")"
            + " markerStyle=" + style
            + " bitmap=" + (drewNative ? "BRACK0-3" : (m_markerBitmapName + ":" + m_markerBitmapW + "x" + m_markerBitmapH))
            + " box=(" + SS2FA_GetInt("ss2fa_selection_debug_marker_half_w_px", 48) + "," + SS2FA_GetInt("ss2fa_selection_debug_marker_half_h_px", 32) + ")"
            + " best=(" + ((best != null) ? ("d=" + format("%.2f", best.dist) + " a=" + format("%.2f", best.along)
                + (("screenDist" in best) ? (" sd=" + format("%.1f", best.screenDist)) : "")
                + " " + best.reason) : "none") + ")"
            + " name=" + SS2FA_ObjName(target)
            + " arch=" + SS2FA_ArchName(target));
    }

    function OnFrameUpdate(deltaTime)
    {
        if(SS2FA_GetInt("ss2fa_selection_semantic", 0) == 0){
            ClearTarget();
            return;
        }
        local aim = SS2FA_ReadAim();
        if(aim == null){
            ClearTarget();
            return;
        }
        if(!m_loggedActive){
            m_loggedActive = true;
            if(SS2FA_GetInt("ss2fa_selection_semantic_log", 0) != 0)
                ::print("[SS2FA-SEL] semantic selection active");
        }

        local now = ShockGame.SimTime();
        local interval = SS2FA_GetInt("ss2fa_selection_semantic_interval_ms", 80);
        if(m_lastScan == null || interval <= 0 || now - m_lastScanTime >= interval){
            m_lastScan = SS2FA_ScanSelection(aim);
            m_lastScanTime = now;
        }

        local target = (m_lastScan != null) ? m_lastScan.target : 0;
        local publishInterval = SS2FA_GetInt("ss2fa_selection_semantic_publish_interval_ms", 160);
        if(target != m_lastTarget || publishInterval <= 0 || now - m_lastPublishTime >= publishInterval){
            SS2FA_PublishSelectionTarget(target);
            m_lastPublishTime = now;
        }

        local logEnabled = SS2FA_GetInt("ss2fa_selection_semantic_log", 0) != 0;
        if(logEnabled && (target != m_lastTarget || now - m_lastLogTime > 1000)){
            m_lastLogTime = now;
            local summary = (m_lastScan != null) ? SS2FA_TopSummary(m_lastScan.top) : "";
            local rejectSummary = (m_lastScan != null) ? SS2FA_TopSummary(m_lastScan.rejectTop) : "";
            ::print("[SS2FA-SEL] target=" + target
                + " scanned=" + ((m_lastScan != null) ? m_lastScan.scanned : 0)
                + " considered=" + ((m_lastScan != null) ? m_lastScan.considered : 0)
                + " rejected=" + ((m_lastScan != null) ? m_lastScan.rejected : 0)
                + " mode=" + ((m_lastScan != null && ("mode" in m_lastScan)) ? m_lastScan.mode : "?")
                + " reach=" + ((m_lastScan != null) ? format("%.2f", m_lastScan.reach) : "0.00")
                + " radius=" + ((m_lastScan != null) ? format("%.2f", m_lastScan.radius) : "0.00")
                + " require=" + ((m_lastScan != null && m_lastScan.requireSemantic) ? "1" : "0")
                + ((m_lastScan != null && ("reticle" in m_lastScan)) ? (" reticle=(" + format("%.1f", m_lastScan.reticle.x) + "," + format("%.1f", m_lastScan.reticle.y) + ")") : "")
                + " ray=(" + format("%.2f", aim.wdx) + "," + format("%.2f", aim.wdy) + "," + format("%.2f", aim.wdz) + ")"
                + " name=" + SS2FA_ObjName(target)
                + " arch=" + SS2FA_ArchName(target)
                + " frob=" + SS2FA_FrobInfoText(target));
            if(summary.len() > 0) ::print("[SS2FA-SELSCAN] " + summary);
            if(rejectSummary.len() > 0) ::print("[SS2FA-SELREJ] " + rejectSummary);
        }
        DrawDebugMarker(target, m_lastScan);
        m_lastTarget = target;
    }
}

// Build a world aim ray by applying the crosshair offset (dyaw,dpitch in degrees) as a
// FLAT-SCREEN ray in the locked-view frame: forward + tan(dyaw)*viewRight + tan(dpitch)*viewUp.
// This matches the on-screen crosshair at any pitch and has NO pole pinch -- unlike adding
// the offset to the WORLD heading/pitch, which compresses the aim toward vertical near the
// poles (the bug that affected both the bullet and the gun).
function SS2FA_ViewFrameAim(dyaw, dpitch)
{
    local basis = SS2FA_FlatCameraScreenBasis();
    local ry = dyaw * SS2FA_GetFloat("ss2fa_view_aim_yaw_sign", 1.0) * SS2FA_PI / 180.0;
    local rp = dpitch * SS2FA_GetFloat("ss2fa_view_aim_pitch_sign", 1.0) * SS2FA_PI / 180.0;
    local cy = cos(ry);
    local cp = cos(rp);
    local ty = (cy > 0.0001) ? sin(ry) / cy : 0.0;
    local tp = (cp > 0.0001) ? sin(rp) / cp : 0.0;
    local f = basis.forward;
    local r = basis.right;
    local u = basis.up;
    return SS2FA_NormalizeVec(
        vector(f.x + ty * r.x + tp * u.x, f.y + ty * r.y + tp * u.y, f.z + ty * r.z + tp * u.z),
        f
    );
}

// Same flat-screen view-frame ray, but on a CALLER-SUPPLIED forward (e.g. the engine's native
// launch direction). Used for the projectile velocity, because FlatCameraScreenBasis.forward is
// ~180deg off in azimuth (the gun only survives that via its facing reflection; a raw velocity
// does not). Building on the true forward gives a velocity that points at the crosshair.
function SS2FA_ViewFrameAimFrom(fwd, dyaw, dpitch)
{
    local f = SS2FA_NormalizeVec(fwd, vector(1.0, 0.0, 0.0));
    local worldUp = vector(0.0, 0.0, 1.0);
    local r = SS2FA_NormalizeVec(SS2FA_Cross(f, worldUp), vector(1.0, 0.0, 0.0));
    local u = SS2FA_NormalizeVec(SS2FA_Cross(r, f), worldUp);
    local ry = dyaw * SS2FA_GetFloat("ss2fa_view_aim_yaw_sign", 1.0) * SS2FA_PI / 180.0;
    local rp = dpitch * SS2FA_GetFloat("ss2fa_view_aim_pitch_sign", 1.0) * SS2FA_PI / 180.0;
    local cy = cos(ry);
    local cp = cos(rp);
    local ty = (cy > 0.0001) ? sin(ry) / cy : 0.0;
    local tp = (cp > 0.0001) ? sin(rp) / cp : 0.0;
    return SS2FA_NormalizeVec(
        vector(f.x + ty * r.x + tp * u.x, f.y + ty * r.y + tp * u.y, f.z + ty * r.z + tp * u.z),
        f
    );
}

function SS2FA_ApplyAimOffset(baseDir, aim)
{
    // Legacy world-offset path. The live default now overrides this below with
    // ss2fa_proj_viewframe=1, building the Freelook offset on the native projectile vector.
    if(SS2FA_GetInt("ss2fa_view_frame_aim_projectile", 0) != 0){
        return SS2FA_ViewFrameAim(aim.dyaw, aim.dpitch);
    }
    local dir = SS2FA_NormalizeVec(baseDir, vector(0.0, 1.0, 0.0));
    local headingSign = SS2FA_GetFloat("ss2fa_projectile_heading_sign", SS2FA_GetFloat("ss2fa_weapon_heading_sign", 1.0));
    local pitchSign = SS2FA_GetFloat("ss2fa_projectile_pitch_sign", SS2FA_GetFloat("ss2fa_weapon_pitch_sign", 1.0));
    local heading = SS2FA_WorldHeadingDeg(dir.x, dir.y) + aim.dyaw * headingSign + SS2FA_GetFloat("ss2fa_projectile_heading_offset", 0.0);
    local pitch = SS2FA_WorldPitchDeg(dir.x, dir.y, dir.z) + aim.dpitch * pitchSign + SS2FA_GetFloat("ss2fa_projectile_pitch_offset", 0.0);
    return SS2FA_DirFromHeadingPitchDeg(heading, pitch);
}

//----------------------------------------------------------------------------
//  Projectile redirect (the bullet follows the crosshair) — COMPLETE
//----------------------------------------------------------------------------
function SS2FA_RedirectProjectile(proj, phase)
{
    if(SS2FA_GetInt("ss2fa_enable", 1) == 0) return;
    local aim = SS2FA_ReadAim();
    if(aim == null) return;

    local player = ND.g_PlayerCore.GetPlayer();
    if(Property.Get(proj, "Firer") != player) return;

    local originalVelocity = SS2FA_GetProjVel(proj);
    local originalSpeed = SS2FA_VecLen(originalVelocity);
    local dir = SS2FA_NormalizeVec(vector(aim.wdx, aim.wdy, aim.wdz), vector(0.0, 1.0, 0.0));
    local originalDir = SS2FA_NormalizeVec(originalVelocity, dir);
    local mode = SS2FA_GetInt("ss2fa_projectile_mode", 2);
    local basis = "dll";
    local camHeading = 0.0;
    local camPitch = 0.0;
    local haveCameraFacing = false;
    try {
        local cameraFacing = Camera.GetFacing();
        camHeading = cameraFacing.z;
        camPitch = cameraFacing.y;
        haveCameraFacing = true;
    } catch(e) {}

    if(mode == 2){
        if(originalSpeed <= 0.0001 && SS2FA_GetInt("ss2fa_projectile_native_skip_create", 1) != 0){
            if(SS2FA_GetInt("ss2fa_aim_log", 0) != 0)
                ::print("[SS2FA] redirect skipped phase=" + phase + " proj=" + proj
                    + " mode=2 reason=no_native_velocity aimOff=(" + aim.dyaw + "," + aim.dpitch + ")");
            return;
        }
        if(originalSpeed > 0.0001){
            dir = SS2FA_ApplyAimOffset(originalDir, aim);
            basis = "native_velocity";
        }
    } else if(mode == 1 && haveCameraFacing){
        dir = SS2FA_ApplyAimOffset(SS2FA_DirFromHeadingPitchDeg(camHeading, camPitch), aim);
        basis = "camera_facing";
    }

    // Confirmed live: build the Freelook offset on the engine's native launch direction. This
    // avoids the old 180-degree view-frame reflection and removes pole pitch collapse.
    local projViewFrame = SS2FA_GetInt("ss2fa_proj_viewframe", 1) != 0;
    if(projViewFrame){
        // Velocity built on the engine's NATIVE aim (true forward), not the 180deg-off basis.
        dir = SS2FA_ViewFrameAimFrom(originalDir, aim.dyaw, aim.dpitch);
        basis = "view_frame_native";
    }

    local speed = originalSpeed;
    if(speed <= 0.0001) speed = SS2FA_GetFloat("ss2fa_default_speed", 100.0);

    local facing = null;
    local projFacingMode = SS2FA_GetInt("ss2fa_proj_facing_mode", 1);
    local nativeFacing = null;
    try { nativeFacing = Object.Facing(proj); } catch(eNativeFace) {}
    if(projViewFrame && projFacingMode == 0){
        // Old behavior: visually screen-upright like the proxy gun. Kept as an A/B probe
        // because laser bolts expose projectile-object facing independently of velocity.
        facing = SS2FA_DirToProxyFacingViewRelative(dir.x, dir.y, dir.z);
    } else {
        facing = SS2FA_DirToProjectileObjectFacing(dir.x, dir.y, dir.z, nativeFacing, projViewFrame && projFacingMode == 2);
    }
    local origin = vector(aim.wox, aim.woy, aim.woz);
    local teleported = 0;
    // ISOLATION PROBE: figure out whether the shot follows the facing or the velocity.
    //   ss2fa_proj_skip_facing=1 -> don't set facing (only position+velocity). If shots then
    //       track the crosshair, the bullet follows VELOCITY and the facing was interfering.
    //   ss2fa_proj_skip_vel=1    -> don't set velocity (only facing). Shots then reveal the
    //       facing convention.
    if(SS2FA_GetInt("ss2fa_proj_skip_facing", 0) != 0){
        teleported = 0;   // skip teleport: keep native position+facing, isolate velocity
    } else {
        try { Object.Teleport(proj, origin, facing); teleported = 1; } catch(e) {}
    }
    local mask = 0;
    if(SS2FA_GetInt("ss2fa_proj_skip_vel", 0) == 0){
        mask = SS2FA_SetProjVel(proj, vector(dir.x * speed, dir.y * speed, dir.z * speed));
    }

    if(SS2FA_GetInt("ss2fa_projdbg", 0) != 0 && phase == "deferred"){
        local vf = SS2FA_ViewFrameAim(aim.dyaw, aim.dpitch);
        ::print("[SS2FA-PROJDBG] proj=" + proj
            + " native=" + SS2FA_FormatVec(originalDir)
            + " used=" + SS2FA_FormatVec(dir)
            + " viewFrame=" + SS2FA_FormatVec(vf)
            + " facing=(" + format("%.1f", facing.x) + "," + format("%.1f", facing.y) + "," + format("%.1f", facing.z) + ")"
            + " dyawPitch=(" + format("%.1f", aim.dyaw) + "," + format("%.1f", aim.dpitch) + ")"
            + " vfOn=" + (projViewFrame ? "1" : "0")
            + " projFaceMode=" + projFacingMode);
    }

    if(SS2FA_GetInt("ss2fa_aim_log", 0) != 0){
        ::print("[SS2FA] redirect phase=" + phase + " proj=" + proj + " teleported=" + teleported
            + " mask=" + mask + " speed=" + speed + " oldSpeed=" + originalSpeed
            + " mode=" + mode + " basis=" + basis
            + " projFaceMode=" + projFacingMode
            + " cam=(" + camHeading + "," + camPitch + ")"
            + " aimOff=(" + aim.dyaw + "," + aim.dpitch + ")");
        ::print("[SS2FA] redirect vec proj=" + proj
            + " native=(" + originalDir.x + "," + originalDir.y + "," + originalDir.z + ")"
            + " out=(" + dir.x + "," + dir.y + "," + dir.z + ")"
            + " facing=(" + facing.x + "," + facing.y + "," + facing.z + ")");
    }
}

class SS2FAShootAim extends SqRootScript
{
    // OnCreate fires before the engine assigns the launch velocity (oldSpeed=0),
    // so we re-apply on a one-shot timer (lesson from the VR aim work).
    function OnCreate()
    {
        SS2FA_RedirectProjectile(self, "create");
        SetOneShotTimer("SS2FAReaim", SS2FA_GetFloat("ss2fa_defer_seconds", 0.001));
    }
    function OnTimer()
    {
        if(message().name == "SS2FAReaim")
            SS2FA_RedirectProjectile(self, "deferred");
    }
}

function SS2FA_InstallProjectileScript()
{
    foreach(name in ["Pistol & Rifle Projectiles", "Energy Projectiles", "Shotgun Projectiles", "Grenade Projectiles", "Psi Projectiles"])
    {
        local a = Object.Named(name);
        if(a == 0) continue;
        if(!Property.Possessed(a, "Scripts")) Property.Add(a, "Scripts");
        Property.Set(a, "Scripts", "Script 1", "SS2FAShootAim");   // base NDShootTriggerScript stays Script 0
        if(SS2FA_GetInt("ss2fa_aim_log", 0) != 0)
            ::print("[SS2FA] attached SS2FAShootAim to '" + name + "'");
    }
}

//----------------------------------------------------------------------------
//  Rig-level weapon follow diagnostic
//
//  Mode 5 enters the native viewmodel script before the final CameraObj write:
//  aimPoint gets the Freelook yaw/pitch, then the stock gunPoint -> CameraObj
//  path runs normally. This avoids another post-hoc Heading/Pitch/Bank tweak.
//----------------------------------------------------------------------------
class SS2FAGunViewmodel extends NDShockGunViewmodel
{
    m_ss2faLoggedRig = false;
    m_ss2faLoggedEffect = false;
    m_ss2faLastRigLogTime = 0;

    function SpawnMuzzleFlash()
    {
        if(!SS2FA_ProxyEffectsActive() || !m_data){
            base.SpawnMuzzleFlash();
            return;
        }
        if(Object.Exists(m_muzzleFlashObj)){
            return;
        }

        foreach(spawn in m_data.m_spawns){
            if(spawn.type == "flash"){
                local pose = SS2FA_ProxyRigPointPose(m_data.GetPointRig(), "muzzleFlashPoint");
                if(pose == null){
                    base.SpawnMuzzleFlash();
                    return;
                }
                try {
                    Networking.Suspend();
                    m_muzzleFlashObj = Object.Create(spawn.name);
                    if(!Property.Possessed(m_muzzleFlashObj, "CameraObj")) Property.Add(m_muzzleFlashObj, "CameraObj");
                    Property.Set(m_muzzleFlashObj, "CameraObj", "Offset", pose.cameraLocal);
                    Property.Set(m_muzzleFlashObj, "CameraObj", "Bank", SS2FA_DegToDark(pose.facing.x) + Data.RandInt(0, 65535));
                    Property.Set(m_muzzleFlashObj, "CameraObj", "Pitch", SS2FA_DegToDark(pose.facing.y));
                    Property.Set(m_muzzleFlashObj, "CameraObj", "Heading", SS2FA_DegToDark(pose.facing.z));
                    Networking.Resume();
                    if(SS2FA_GetInt("ss2fa_weapon_effect_log", 0) != 0){
                        ::print("[SS2FA-FX] muzzle proxy obj=" + m_muzzleFlashObj
                            + " proxy=" + SS2FA.weaponProxyObj
                            + " world=" + SS2FA_FormatVec(pose.world)
                            + " cameraLocal=" + SS2FA_FormatVec(pose.cameraLocal)
                            + " localDelta=" + SS2FA_FormatVec(pose.localDelta)
                            + " facing=(" + format("%.2f", pose.facing.x) + "," + format("%.2f", pose.facing.y) + "," + format("%.2f", pose.facing.z) + ")");
                    }
                } catch(e) {
                    try { Networking.Resume(); } catch(e2) {}
                    ::print("[SS2FA-FX] muzzle proxy spawn failed: " + e.tostring());
                    try {
                        if(Object.Exists(m_muzzleFlashObj)) Object.Destroy(m_muzzleFlashObj);
                    } catch(eDestroy) {}
                    m_muzzleFlashObj = 0;
                    base.SpawnMuzzleFlash();
                }
            }
        }
    }

    function SpawnEjects()
    {
        if(!SS2FA_ProxyEffectsActive() || !m_data){
            base.SpawnEjects();
            return;
        }

        foreach(spawn in m_data.m_spawns){
            if(spawn.type == "eject"){
                local eject = Physics.LaunchProjectile(self, spawn.name, 1.0, 0, vector(0.0, 0.0, 0.0));
                local pose = SS2FA_ProxyRigPointPose(m_data.GetPointRig(), "vhot" + spawn.vhot);
                if(pose == null){
                    try { Object.Teleport(eject, m_data.GetPointRig().Get("vhot" + spawn.vhot).GetWorldPos(), Camera.GetFacing()); } catch(eNative) {}
                    continue;
                }
                try {
                    Object.Teleport(eject, pose.world, pose.facing);
                    if(SS2FA_GetInt("ss2fa_weapon_effect_log", 0) != 0){
                        ::print("[SS2FA-FX] eject proxy obj=" + eject
                            + " proxy=" + SS2FA.weaponProxyObj
                            + " vhot=" + spawn.vhot
                            + " world=" + SS2FA_FormatVec(pose.world)
                            + " localDelta=" + SS2FA_FormatVec(pose.localDelta)
                            + " facing=(" + format("%.2f", pose.facing.x) + "," + format("%.2f", pose.facing.y) + "," + format("%.2f", pose.facing.z) + ")");
                    }
                } catch(e) {
                    ::print("[SS2FA-FX] eject proxy teleport failed: " + e.tostring());
                }
            }
        }
    }

    function OnFrameUpdate()
    {
        SS2FA.effectViewmodelActive = true;
        if(!m_ss2faLoggedEffect && SS2FA_GetInt("ss2fa_weapon_effect_log", 0) != 0){
            m_ss2faLoggedEffect = true;
            ::print("[SS2FA-FX] Freelook viewmodel subclass active");
        }

        local mode = SS2FA_GetInt("ss2fa_weapon_follow_mode", 1);
        local aim = (mode == 5) ? SS2FA_ReadAim() : null;
        if(mode != 5 || aim == null){
            base.OnFrameUpdate();
            return;
        }

        SS2FA.rigViewmodelActive = true;

        if(!m_data){
            ND.g_PlayerCore.InternalMessage("ViewmodelNeedsInit");
            return;
        }

        local playerSpeed = message().data;
        local deltaTime = message().data2;

        CalculateProcedurals(playerSpeed, deltaTime);

        local finMovePos = vector(0.0, m_procedurals.horizontalBob*0.1, -m_procedurals.verticalBob*0.02);
        local finMoveRot = vector(0.0, m_procedurals.verticalBob*1.0, 0.0);
        local finIdlePos = vector(-m_procedurals.armReach, 0.0, -m_procedurals.idleBreathe*0.04);
        local finIdleRot = vector(0.0, 0.0, 0.0);
        local finLeanPos = vector(0.0, 0.0, 0.0);
        local finLeanRot = vector(m_procedurals.horizontalLean*1.25, m_procedurals.verticalLean*1.25, 0.0);
        local finWallPos = vector(0.0, 0.0, -0.2);
        local finWallRot = vector(20.0, -45.0, 0.0);

        local combinedPos = m_procedurals.offset + (finMovePos*m_procedurals.moveSpeed) + finIdlePos + finLeanPos + (finWallPos*m_procedurals.wallLean);
        local combinedRot = (finMoveRot*m_procedurals.moveSpeed) + finIdleRot + finLeanRot + (finWallRot*m_procedurals.wallLean);

        local rigHeading = aim.dyaw * SS2FA_GetFloat("ss2fa_weapon_heading_sign", 1.0);
        local rigPitch = aim.dpitch * SS2FA_GetFloat("ss2fa_weapon_pitch_sign", 1.0);
        local rigBank = SS2FA_GetFloat("ss2fa_weapon_bank_deg", 0.0);
        combinedRot.x += rigHeading;
        combinedRot.y += rigPitch;
        combinedRot.z += rigBank;

        m_data.GetPointRig().LerpPos("aimPoint", combinedPos.x, combinedPos.y, combinedPos.z, 16);
        m_data.GetPointRig().LerpRot("aimPoint", combinedRot.x, combinedRot.y, combinedRot.z, 16);
        m_data.GetPointRig().Update(this);

        if(m_data.m_name == "Psi Amp"){
            local cableBobValue = m_procedurals.secondaryBob;
            m_data.GetPointRig().Get("joint1").LerpPos(((cableBobValue) * 20) * m_procedurals.moveSpeed, 0.0, 0.0, 50);
        }

        Property.Set(self, "JointPos", "Joint 1", m_data.GetPointRig().Get("joint1").GetLocalPos().x );
        Property.Set(self, "JointPos", "Joint 2", m_data.GetPointRig().Get("joint2").GetLocalPos().x );
        Property.Set(self, "JointPos", "Joint 3", m_data.GetPointRig().Get("joint3").GetLocalPos().x );

        SetProperty("CameraObj", "Offset", m_data.GetPointRig().Get("gunPoint").GetPos());
        SetProperty("CameraObj", "Bank", m_data.GetPointRig().Get("gunPoint").GetBank());
        SetProperty("CameraObj", "Pitch", m_data.GetPointRig().Get("gunPoint").GetPitch());
        SetProperty("CameraObj", "Heading", m_data.GetPointRig().Get("gunPoint").GetHeading());

        local lockHeading = SS2FA_GetInt("ss2fa_weapon_lock_heading", 0) != 0;
        local lockPitch = SS2FA_GetInt("ss2fa_weapon_lock_pitch", 0) != 0;
        local lockBank = SS2FA_GetInt("ss2fa_weapon_lock_bank", 0) != 0;
        SetProperty("CameraObj", "Lock Heading?", lockHeading);
        SetProperty("CameraObj", "Lock Pitch?", lockPitch);
        SetProperty("CameraObj", "Lock Bank?", lockBank);

        local now = ShockGame.SimTime();
        if(SS2FA_GetInt("ss2fa_aim_log", 0) != 0 && (!m_ss2faLoggedRig || now - m_ss2faLastRigLogTime > 1000)){
            m_ss2faLoggedRig = true;
            m_ss2faLastRigLogTime = now;
            local gunPoint = m_data.GetPointRig().Get("gunPoint");
            ::print("[SS2FA-RIG] mode=5 active aimPoint=("
                + format("%.2f", rigHeading) + "," + format("%.2f", rigPitch) + "," + format("%.2f", rigBank) + ")"
                + " combinedRot=(" + format("%.2f", combinedRot.x) + "," + format("%.2f", combinedRot.y) + "," + format("%.2f", combinedRot.z) + ")"
                + " gunRot=(" + format("%.2f", gunPoint.GetRot().x) + "," + format("%.2f", gunPoint.GetRot().y) + "," + format("%.2f", gunPoint.GetRot().z) + ")"
                + " gunOff=(" + format("%.3f", gunPoint.GetPos().x) + "," + format("%.3f", gunPoint.GetPos().y) + "," + format("%.3f", gunPoint.GetPos().z) + ")"
                + " lock=(" + (lockHeading ? "1" : "0") + "," + (lockPitch ? "1" : "0") + "," + (lockBank ? "1" : "0") + ")");
        }
    }
}

class SS2FAMeleeViewmodel extends NDShockMeleeViewmodel
{
    m_ss2faLoggedMelee = false;
    m_ss2faLoggedNoArm = false;
    m_ss2faLastPoseLogTime = 0;

    function OnFrameUpdate()
    {
        base.OnFrameUpdate();

        if(SS2FA_GetInt("ss2fa_melee_enable", 1) == 0) return;
        if(SS2FA_GetInt("ss2fa_weapon_follow_mode", 1) != 7) return;

        local aim = SS2FA_ReadAim();
        if(aim == null) return;

        local playerArm = 0;
        try { playerArm = Object.Named("PlyrArm"); } catch(eArm) { playerArm = 0; }
        if(playerArm == 0 || !Object.Exists(playerArm)){
            if(!m_ss2faLoggedNoArm){
                m_ss2faLoggedNoArm = true;
                ::print("[SS2FA-MELEE] PlyrArm not found; melee Freelook skipped");
            }
            return;
        }

        SS2FA.meleeViewmodelActive = true;
        SS2FA.meleeViewmodelLastActiveTime = ShockGame.SimTime();

        local baseWorldPos = null;
        try {
            baseWorldPos = Property.Get(playerArm, "Position", "Location");
        } catch(ePos) {
            try { baseWorldPos = Camera.CameraToWorld(vector(0.2, -0.6, -2.4)); }
            catch(eCam) { baseWorldPos = vector(0.0, 0.0, 0.0); }
        }

        local aimDir = vector(aim.wdx, aim.wdy, aim.wdz);
        if(SS2FA_GetInt("ss2fa_view_frame_aim", 1) != 0){
            aimDir = SS2FA_ViewFrameAim(aim.dyaw, aim.dpitch);
        }

        local lookDistance = SS2FA_GetFloat("ss2fa_melee_look_distance", SS2FA_GetFloat("ss2fa_weapon_proxy_look_distance", 40.0));
        if(lookDistance < 1.0) lookDistance = 1.0;
        local target = vector(
            aim.wox + aimDir.x * lookDistance,
            aim.woy + aimDir.y * lookDistance,
            aim.woz + aimDir.z * lookDistance
        );
        local proxyDir = SS2FA_NormalizeVec(
            vector(target.x - baseWorldPos.x, target.y - baseWorldPos.y, target.z - baseWorldPos.z),
            aimDir
        );

        local nativeFacing = vector(0.0, 0.0, 0.0);
        try {
            nativeFacing = vector(
                SS2FA_DarkToDeg(Property.Get(playerArm, "Position", "Bank")),
                SS2FA_DarkToDeg(Property.Get(playerArm, "Position", "Pitch")),
                SS2FA_DarkToDeg(Property.Get(playerArm, "Position", "Heading"))
            );
        } catch(eFacing) {}

        local savedFwd = SS2FA.proxyBasisForward;
        local savedRight = SS2FA.proxyBasisRight;
        local savedUp = SS2FA.proxyBasisUp;
        local savedRollRaw = SS2FA.proxyRollRaw;
        local savedRollApplied = SS2FA.proxyRollApplied;
        local savedRollSign = SS2FA.proxyRollSign;
        local savedRollKill = SS2FA.proxyRollKill;
        local proxyFacing = SS2FA_DirToProxyFacingViewRelative(proxyDir.x, proxyDir.y, proxyDir.z);
        SS2FA.proxyBasisForward = savedFwd;
        SS2FA.proxyBasisRight = savedRight;
        SS2FA.proxyBasisUp = savedUp;
        SS2FA.proxyRollRaw = savedRollRaw;
        SS2FA.proxyRollApplied = savedRollApplied;
        SS2FA.proxyRollSign = savedRollSign;
        SS2FA.proxyRollKill = savedRollKill;

        local orientationMode = SS2FA_GetInt("ss2fa_melee_orientation_mode", 3);
        local headingSign = SS2FA_GetFloat("ss2fa_melee_heading_sign", -1.0);
        local pitchSign = SS2FA_GetFloat("ss2fa_melee_pitch_sign", 1.0);
        local bankSign = SS2FA_GetFloat("ss2fa_melee_bank_sign", 1.0);
        local facing = nativeFacing;
        local writeFacing = true;
        local offsetBasis = SS2FA_FacingBasis(proxyFacing);
        local screenLocalOffset = vector(0.0, 0.0, 0.0);
        local pointRigOffsetFrame = false;
        if(orientationMode == 1){
            local camFacing = vector(0.0, 0.0, 0.0);
            try {
                local cf = Camera.GetFacing();
                camFacing = vector(
                    SS2FA_SignedAngleDeg(cf.x),
                    SS2FA_SignedAngleDeg(cf.y),
                    SS2FA_SignedAngleDeg(cf.z)
                );
            } catch(eCamFacing) {}
            facing = vector(
                SS2FA_SignedAngleDeg(aim.dpitch * bankSign),
                0.0,
                SS2FA_SignedAngleDeg(camFacing.z + aim.dyaw * headingSign)
            );
        } else if(orientationMode == 2){
            // Legacy first-pass mode: direct gun-proxy world facing. Kept only for A/B.
            facing = proxyFacing;
        } else if(orientationMode == 3){
            // Native NDShockMeleeViewmodel only writes PlyrArm Location. Live Freelook testing
            // showed Heading/Pitch/Bank writes make the wrench orbit/spin around the player.
            // Keep native orientation intact and move the rigid arm in the camera screen plane.
            writeFacing = false;
            facing = nativeFacing;
            pointRigOffsetFrame = true;
            screenLocalOffset = vector(
                SS2FA_GetFloat("ss2fa_melee_forward_per_deg", 0.0) * aim.dpitch,
                SS2FA_GetFloat("ss2fa_melee_left_per_deg", SS2FA_GetFloat("ss2fa_weapon_offset_left_per_deg", -0.015)) * aim.dyaw,
                SS2FA_GetFloat("ss2fa_melee_up_per_deg", SS2FA_GetFloat("ss2fa_weapon_offset_up_per_deg", 0.015)) * aim.dpitch
            );
        } else {
            // orientationMode 0: native melee orientation only. Do not write facing fields.
            facing = nativeFacing;
            writeFacing = false;
        }

        facing = vector(
            SS2FA_SignedAngleDeg(facing.x + SS2FA_GetFloat("ss2fa_melee_bank_offset", 0.0)),
            SS2FA_SignedAngleDeg(facing.y + SS2FA_GetFloat("ss2fa_melee_pitch_offset", 0.0)),
            SS2FA_SignedAngleDeg(facing.z + SS2FA_GetFloat("ss2fa_melee_heading_offset", 0.0))
        );

        local localOffset = null;
        if(pointRigOffsetFrame){
            localOffset = vector(
                SS2FA_GetFloat("ss2fa_melee_forward_offset", 0.0) + screenLocalOffset.x,
                SS2FA_GetFloat("ss2fa_melee_left_offset", 0.0) + screenLocalOffset.y,
                SS2FA_GetFloat("ss2fa_melee_up_offset", 0.0) + screenLocalOffset.z
            );
        } else {
            localOffset = vector(
                SS2FA_GetFloat("ss2fa_melee_forward_offset", 0.0) + screenLocalOffset.x,
                SS2FA_GetFloat("ss2fa_melee_left_offset", 0.0) + screenLocalOffset.y,
                SS2FA_GetFloat("ss2fa_melee_up_offset", 0.0) + screenLocalOffset.z
            );
        }
        local worldOffset = pointRigOffsetFrame
            ? SS2FA_PointLocalToWorldOffset(localOffset)
            : SS2FA_ProxyLocalToWorldOffset(localOffset, offsetBasis);
        local worldPos = vector(
            baseWorldPos.x + worldOffset.x,
            baseWorldPos.y + worldOffset.y,
            baseWorldPos.z + worldOffset.z
        );

        try {
            local scale = SS2FA_GetFloat("ss2fa_melee_scale", 1.0);
            if(scale > 0.0 && scale != 1.0){
                if(!Property.Possessed(playerArm, "Scale")) Property.Add(playerArm, "Scale");
                Property.Set(playerArm, "Scale", "", vector(scale, scale, scale));
            }
        } catch(eScale) {}

        try {
            Property.Set(playerArm, "Position", "Location", worldPos);
            if(writeFacing){
                Property.Set(playerArm, "Position", "Heading", SS2FA_DegToDark(facing.z));
                Property.Set(playerArm, "Position", "Pitch", SS2FA_DegToDark(facing.y));
                Property.Set(playerArm, "Position", "Bank", SS2FA_DegToDark(facing.x));
            }
        } catch(eSet) {
            ::print("[SS2FA-MELEE] PlyrArm pose write failed: " + eSet.tostring());
            return;
        }

        local now = ShockGame.SimTime();
        if(!m_ss2faLoggedMelee){
            m_ss2faLoggedMelee = true;
            if(SS2FA_GetInt("ss2fa_melee_pose_log", 0) != 0)
                ::print("[SS2FA-MELEE] Freelook melee viewmodel active playerArm=" + playerArm
                    + " viewmodel=" + self
                    + " baseWorld=" + SS2FA_FormatVec(baseWorldPos)
                    + " world=" + SS2FA_FormatVec(worldPos)
                    + " mode=" + orientationMode
                    + " writeFacing=" + (writeFacing ? "1" : "0")
                    + " offsetFrame=" + (pointRigOffsetFrame ? "pointRig" : "proxy")
                    + " nativeFacing=(" + format("%.2f", nativeFacing.x) + "," + format("%.2f", nativeFacing.y) + "," + format("%.2f", nativeFacing.z) + ")"
                    + " proxyFacing=(" + format("%.2f", proxyFacing.x) + "," + format("%.2f", proxyFacing.y) + "," + format("%.2f", proxyFacing.z) + ")"
                    + " facing=(" + format("%.2f", facing.x) + "," + format("%.2f", facing.y) + "," + format("%.2f", facing.z) + ")"
                    + " aimDir=" + SS2FA_FormatVec(aimDir)
                    + " proxyDir=" + SS2FA_FormatVec(proxyDir)
                    + " aimOff=(" + format("%.2f", aim.dyaw) + "," + format("%.2f", aim.dpitch) + ")"
                    + " screenLocal=" + SS2FA_FormatVec(screenLocalOffset)
                    + " localOffset=" + SS2FA_FormatVec(localOffset)
                    + " lookDist=" + format("%.1f", lookDistance));
        }
        if(SS2FA_GetInt("ss2fa_melee_pose_log", 0) != 0 && now - m_ss2faLastPoseLogTime > 500){
            m_ss2faLastPoseLogTime = now;
            ::print("[SS2FA-MELEE] pose playerArm=" + playerArm
                + " world=" + SS2FA_FormatVec(worldPos)
                + " mode=" + orientationMode
                + " writeFacing=" + (writeFacing ? "1" : "0")
                + " offsetFrame=" + (pointRigOffsetFrame ? "pointRig" : "proxy")
                + " nativeFacing=(" + format("%.2f", nativeFacing.x) + "," + format("%.2f", nativeFacing.y) + "," + format("%.2f", nativeFacing.z) + ")"
                + " proxyFacing=(" + format("%.2f", proxyFacing.x) + "," + format("%.2f", proxyFacing.y) + "," + format("%.2f", proxyFacing.z) + ")"
                + " facing=(" + format("%.2f", facing.x) + "," + format("%.2f", facing.y) + "," + format("%.2f", facing.z) + ")"
                + " aimDir=" + SS2FA_FormatVec(aimDir)
                + " proxyDir=" + SS2FA_FormatVec(proxyDir)
                + " aimOff=(" + format("%.2f", aim.dyaw) + "," + format("%.2f", aim.dpitch) + ")"
                + " screenLocal=" + SS2FA_FormatVec(screenLocalOffset)
                + " localOffset=" + SS2FA_FormatVec(localOffset));
        }
    }
}

function SS2FA_InstallRigViewmodelProbe()
{
    if(!("rigViewmodelInstallTried" in SS2FA)) SS2FA.rigViewmodelInstallTried <- false;
    if(!("rigViewmodelInstalled" in SS2FA)) SS2FA.rigViewmodelInstalled <- false;
    if(!("rigViewmodelActive" in SS2FA)) SS2FA.rigViewmodelActive <- false;
    if(SS2FA.rigViewmodelInstallTried && SS2FA.rigViewmodelInstalled) return;
    SS2FA.rigViewmodelInstallTried = true;
    SS2FA.rigViewmodelInstalled = false;
    SS2FA.rigViewmodelActive = false;

    local arch = 0;
    try { arch = Object.Named("NDShockGunViewmodel"); } catch(e) { arch = 0; }
    if(arch == 0){
        ::print("[SS2FA-RIG] viewmodel archetype not found; mode 5 unavailable");
        return;
    }

    local oldScript = "";
    try {
        if(!Property.Possessed(arch, "Scripts")) Property.Add(arch, "Scripts");
        oldScript = Property.Get(arch, "Scripts", "Script 0");
    } catch(e) {
        ::print("[SS2FA-RIG] viewmodel script read failed: " + e.tostring());
        return;
    }

    try {
        if(oldScript != "SS2FAGunViewmodel"){
            try {
                Property.SetLocal(arch, "Scripts", "Script 0", "SS2FAGunViewmodel");
            } catch(e) {
                Property.Set(arch, "Scripts", "Script 0", "SS2FAGunViewmodel");
            }
        }
        local newScript = Property.Get(arch, "Scripts", "Script 0");
        SS2FA.rigViewmodelInstalled = (newScript == "SS2FAGunViewmodel");
        if(SS2FA_GetInt("ss2fa_aim_log", 0) != 0)
            ::print("[SS2FA-RIG] viewmodel archetype script0 old=" + oldScript
                + " new=" + newScript
                + " installed=" + (SS2FA.rigViewmodelInstalled ? "1" : "0")
                + " mode5=aimPoint");
    } catch(e) {
        ::print("[SS2FA-RIG] viewmodel archetype patch failed: " + e.tostring());
    }
}

function SS2FA_InstallMeleeViewmodelProbe()
{
    if(!("meleeViewmodelInstallTried" in SS2FA)) SS2FA.meleeViewmodelInstallTried <- false;
    if(SS2FA.meleeViewmodelInstallTried && SS2FA.meleeViewmodelInstalled) return;
    SS2FA.meleeViewmodelInstallTried = true;
    SS2FA.meleeViewmodelInstalled = false;
    SS2FA.meleeViewmodelActive = false;
    SS2FA.meleeViewmodelLastActiveTime = -999999;

    local arch = 0;
    try { arch = Object.Named("NDShockMeleeViewmodel"); } catch(e) { arch = 0; }
    if(arch == 0){
        ::print("[SS2FA-MELEE] melee viewmodel archetype not found");
        return;
    }

    local oldScript = "";
    try {
        if(!Property.Possessed(arch, "Scripts")) Property.Add(arch, "Scripts");
        oldScript = Property.Get(arch, "Scripts", "Script 0");
    } catch(e) {
        ::print("[SS2FA-MELEE] melee viewmodel script read failed: " + e.tostring());
        return;
    }

    try {
        if(oldScript != "SS2FAMeleeViewmodel"){
            try {
                Property.SetLocal(arch, "Scripts", "Script 0", "SS2FAMeleeViewmodel");
            } catch(e) {
                Property.Set(arch, "Scripts", "Script 0", "SS2FAMeleeViewmodel");
            }
        }
        local newScript = Property.Get(arch, "Scripts", "Script 0");
        SS2FA.meleeViewmodelInstalled = (newScript == "SS2FAMeleeViewmodel");
        if(SS2FA_GetInt("ss2fa_melee_pose_log", 0) != 0)
            ::print("[SS2FA-MELEE] melee viewmodel archetype script0 old=" + oldScript
                + " new=" + newScript
                + " installed=" + (SS2FA.meleeViewmodelInstalled ? "1" : "0"));
    } catch(e) {
        ::print("[SS2FA-MELEE] melee viewmodel archetype patch failed: " + e.tostring());
    }
}

//----------------------------------------------------------------------------
//  Weapon-model follow (gun points at the crosshair) — reuse from probe
//
//  Copy SS2VRFindWeaponHandler from mods/ss2vr_weapon_handoff/.../ss2vr_weapon_probe.nut
//  (it resolves the live NDWeaponHandler -> .m_viewmodelObject). Then per frame set
//  the viewmodel CameraObj Heading/Pitch from the crosshair offset (dyaw/dpitch).
//  Guarded so the kpf still loads + the bullet redirect works even if this is stubbed.
//----------------------------------------------------------------------------
class SS2FA.AimHandler
{
    m_name = "SS2FA_AimHandler";
    m_loggedAim = false;
    m_missingWeaponHandlerLogged = false;
    m_lastViewmodelObject = null;
    m_lastAliveTime = 0;
    m_lastWeaponLogTime = 0;
    m_nativeCrosshairHidden = false;
    m_crosshairBitmap = null;
    m_crosshairBitmapName = "";
    m_crosshairBitmapW = 16;
    m_crosshairBitmapH = 16;
    m_crosshairActiveLogged = false;
    m_crosshairFailureLogged = false;
    m_crosshairDiagLastTime = 0;
    m_crosshairDiagSamples = 0;
    m_baseOffset = null;
    m_baseOffsetObject = null;
    m_mode5RecreateTried = false;
    m_effectRecreateTried = false;
    m_meleeRecreateTried = false;
    m_worldProxyObj = 0;
    m_worldProxyModel = "";
    m_worldProxyLogged = false;
    m_noProxyModelLogged = false;
    m_lastProxyPoseLogTime = 0;
    m_proxyBaselineValid = false;
    m_proxyBaselineUp = null;
    m_proxyBaselineRight = null;
    m_proxyBaselineHeading = 0.0;
    m_proxyBaselinePitch = 0.0;
    m_proxyHeadingBaselineValid = false;
    m_proxyHeadingBaseline = 0.0;
    m_hiddenNativeObj = 0;
    m_hiddenNativeHadScale = false;
    m_hiddenNativeScale = null;

    function Init()
    {
        if(SS2FA_GetInt("ss2fa_aim_log", 0) != 0)
            ::print("[SS2FA] AimHandler init");
    }

    function SetNativeCrosshairHidden(hidden)
    {
        if(hidden){
            if(!m_nativeCrosshairHidden){
                m_crosshairActiveLogged = false;
                m_crosshairDiagLastTime = 0;
                m_crosshairDiagSamples = 0;
                try {
                    ShockGame.OverlayChange(SS2FA_OVERLAY_CROSSHAIR, SS2FA_OVERLAY_MODE_OFF);
                    if(SS2FA_GetInt("ss2fa_aim_log", 0) != 0)
                        ::print("[SS2FA] native crosshair overlay hidden for Freelook");
                } catch(e) {
                    if(!m_crosshairFailureLogged){
                        m_crosshairFailureLogged = true;
                        ::print("[SS2FA] native crosshair hide failed: " + e.tostring());
                    }
                }
            }
            m_nativeCrosshairHidden = true;
            return;
        }

        if(m_nativeCrosshairHidden){
            m_nativeCrosshairHidden = false;
            if(SS2FA_GameplayHudMode()){
                try {
                    ShockGame.OverlayChange(SS2FA_OVERLAY_CROSSHAIR, SS2FA_OVERLAY_MODE_ON);
                    if(SS2FA_GetInt("ss2fa_aim_log", 0) != 0)
                        ::print("[SS2FA] native crosshair overlay restored");
                } catch(e) {
                    if(!m_crosshairFailureLogged){
                        m_crosshairFailureLogged = true;
                        ::print("[SS2FA] native crosshair restore failed: " + e.tostring());
                    }
                }
            }
        }
    }

    function CaptureBaseOffset(vm)
    {
        if(m_baseOffset != null && m_baseOffsetObject == vm) return m_baseOffset;
        try {
            m_baseOffset = Property.Get(vm, "CameraObj", "Offset");
        } catch(e) {
            m_baseOffset = vector(0.0, 0.0, 0.0);
        }
        m_baseOffsetObject = vm;
        if(SS2FA_GetInt("ss2fa_aim_log", 0) != 0)
            ::print("[SS2FA] weapon CameraObj base offset obj=" + vm
                + " off=(" + format("%.3f", m_baseOffset.x) + "," + format("%.3f", m_baseOffset.y) + "," + format("%.3f", m_baseOffset.z) + ")");
        return m_baseOffset;
    }

    function ReadLiveOffset(vm)
    {
        try {
            return Property.Get(vm, "CameraObj", "Offset");
        } catch(e) {
            return CaptureBaseOffset(vm);
        }
    }

    function RestoreNativeViewmodel()
    {
        if(m_hiddenNativeObj == 0) return;
        try {
            if(Object.Exists(m_hiddenNativeObj) && Property.Possessed(m_hiddenNativeObj, "CameraObj")){
                Property.Set(m_hiddenNativeObj, "CameraObj", "Draw?", true);
                if(Property.Possessed(m_hiddenNativeObj, "Scale")){
                    local restoreScale = m_hiddenNativeHadScale ? m_hiddenNativeScale : vector(1.0, 1.0, 1.0);
                    Property.Set(m_hiddenNativeObj, "Scale", "", restoreScale);
                }
                if(SS2FA_GetInt("ss2fa_aim_log", 0) != 0 || SS2FA_GetInt("ss2fa_weapon_proxy_pose_log", 0) != 0)
                    ::print("[SS2FA-PROXY] native viewmodel draw restored obj=" + m_hiddenNativeObj);
            }
        } catch(e) {
            ::print("[SS2FA-PROXY] native viewmodel restore failed: " + e.tostring());
        }
        m_hiddenNativeObj = 0;
        m_hiddenNativeHadScale = false;
        m_hiddenNativeScale = null;
    }

    function HideNativeViewmodel(vm)
    {
        if(SS2FA_GetInt("ss2fa_weapon_proxy_hide_native", 1) == 0){
            RestoreNativeViewmodel();
            return;
        }
        local firstHide = (m_hiddenNativeObj != vm);
        if(firstHide){
            RestoreNativeViewmodel();
            try {
                m_hiddenNativeHadScale = Property.Possessed(vm, "Scale");
                m_hiddenNativeScale = m_hiddenNativeHadScale ? Property.Get(vm, "Scale", "") : vector(1.0, 1.0, 1.0);
            } catch(eCap) {
                m_hiddenNativeHadScale = false;
                m_hiddenNativeScale = vector(1.0, 1.0, 1.0);
            }
            m_hiddenNativeObj = vm;
        }
        try {
            if(Property.Possessed(vm, "CameraObj")){
                Property.Set(vm, "CameraObj", "Draw?", false);
                if(!Property.Possessed(vm, "Scale")) Property.Add(vm, "Scale");
                local hideScale = SS2FA_GetFloat("ss2fa_weapon_proxy_native_hide_scale", 0.001);
                if(hideScale <= 0.0) hideScale = 0.001;
                Property.Set(vm, "Scale", "", vector(hideScale, hideScale, hideScale));
                if(firstHide && (SS2FA_GetInt("ss2fa_aim_log", 0) != 0 || SS2FA_GetInt("ss2fa_weapon_proxy_pose_log", 0) != 0)){
                    ::print("[SS2FA-PROXY] native viewmodel hidden obj=" + vm
                        + " draw=0 scale=" + format("%.4f", hideScale));
                }
            }
        } catch(e) {
            ::print("[SS2FA-PROXY] native viewmodel hide failed: " + e.tostring());
        }
    }

    function DestroyWorldProxy()
    {
        RestoreNativeViewmodel();
        if(m_worldProxyObj != 0){
            try {
                if(Object.Exists(m_worldProxyObj)) Object.Destroy(m_worldProxyObj);
            } catch(e) {}
        }
        m_worldProxyObj = 0;
        m_worldProxyModel = "";
        m_worldProxyLogged = false;
        m_noProxyModelLogged = false;
        m_lastProxyPoseLogTime = 0;
        m_proxyBaselineValid = false;
        m_proxyBaselineUp = null;
        m_proxyBaselineRight = null;
        m_proxyHeadingBaselineValid = false;
        m_proxyHeadingBaseline = 0.0;
        SS2FA.weaponProxyObj = 0;
        SS2FA.proxyValid = false;
        SS2FA.proxyWorldPos = null;
        SS2FA.proxyFacing = null;
    }

    function EnsureProxyBaseline()
    {
        if(m_proxyBaselineValid) return;
        local b = SS2FA_FlatCameraScreenBasis();
        m_proxyBaselineUp = b.up;
        m_proxyBaselineRight = b.right;
        m_proxyBaselineHeading = b.heading;
        m_proxyBaselinePitch = b.pitch;
        m_proxyBaselineValid = true;
        if(SS2FA_GetInt("ss2fa_aim_log", 0) != 0 || SS2FA_GetInt("ss2fa_weapon_proxy_pose_log", 0) != 0)
            ::print("[SS2FA-PROXY] baseline screen basis heading=" + format("%.2f", m_proxyBaselineHeading)
                + " pitch=" + format("%.2f", m_proxyBaselinePitch)
                + " right=(" + format("%.3f", m_proxyBaselineRight.x) + "," + format("%.3f", m_proxyBaselineRight.y) + "," + format("%.3f", m_proxyBaselineRight.z) + ")"
                + " up=(" + format("%.3f", m_proxyBaselineUp.x) + "," + format("%.3f", m_proxyBaselineUp.y) + "," + format("%.3f", m_proxyBaselineUp.z) + ")");
    }

    function EnsureProxyHeadingBaseline(proxyDir, darkHeading)
    {
        if(m_proxyHeadingBaselineValid) return;
        m_proxyHeadingBaseline = darkHeading ? SS2FA_DarkHeadingDeg(proxyDir.x, proxyDir.y) : SS2FA_WorldHeadingDeg(proxyDir.x, proxyDir.y);
        m_proxyHeadingBaselineValid = true;
        if(SS2FA_GetInt("ss2fa_aim_log", 0) != 0 || SS2FA_GetInt("ss2fa_weapon_proxy_pose_log", 0) != 0)
            ::print("[SS2FA-PROXY] heading baseline heading=" + format("%.2f", m_proxyHeadingBaseline)
                + " flipX=" + SS2FA_GetInt("ss2fa_weapon_proxy_flip_x", 0)
                + " dark=" + (darkHeading ? "1" : "0")
                + " proxyDir=" + SS2FA_FormatVec(proxyDir));
    }

    function EnsureWorldProxy(model)
    {
        if(model == "") return 0;
        if(m_worldProxyObj != 0 && Object.Exists(m_worldProxyObj)){
            if(model == m_worldProxyModel) return m_worldProxyObj;
            DestroyWorldProxy();
        }

        local o = 0;
        try { o = Object.Create(-1); } catch(e) {
            ::print("[SS2FA-PROXY] Object.Create failed: " + e.tostring());
            return 0;
        }
        if(o == 0) return 0;

        try { Object.SetTransience(o, true); } catch(eT) {}
        try {
            if(!Property.Possessed(o, "ModelName")) Property.Add(o, "ModelName");
            Property.Set(o, "ModelName", "", model);
            if(!Property.Possessed(o, "Scale")) Property.Add(o, "Scale");
        } catch(e2) {
            ::print("[SS2FA-PROXY] property setup failed obj=" + o + " error=" + e2.tostring());
        }

        m_worldProxyObj = o;
        m_worldProxyModel = model;
        m_worldProxyLogged = false;
        m_lastProxyPoseLogTime = 0;
        // The engine bakes a roll into the rendered viewmodel-proxy equal to f(view
        // pitch at the instant the proxy is created). Capture that pitch now so the
        // per-frame facing can null it (see ss2fa_weapon_proxy_view_roll_comp).
        try { SS2FA.proxyViewPitchAtCreate = SS2FA_SignedAngleDeg(Camera.GetFacing().y); }
        catch(ePc) { SS2FA.proxyViewPitchAtCreate = 0.0; }
        SS2FA.weaponProxyObj = o;
        if(SS2FA_GetInt("ss2fa_aim_log", 0) != 0 || SS2FA_GetInt("ss2fa_weapon_proxy_pose_log", 0) != 0)
            ::print("[SS2FA-PROXY] created world-space proxy obj=" + o + " model=" + model);
        return o;
    }

    function ApplyWorldProxy(vm, aim, now, wh)
    {
        local model = "";
        try {
            if(Property.Possessed(vm, "ModelName")) model = Property.Get(vm, "ModelName", "").tostring();
        } catch(eM) {}
        local weaponName = SS2FA_WeaponNameFromHandler(wh);
        if(model == "" && !m_noProxyModelLogged){
            m_noProxyModelLogged = true;
            if(SS2FA_GetInt("ss2fa_aim_log", 0) != 0)
                ::print("[SS2FA-PROXY] no viewmodel ModelName native=" + vm
                    + " weapon=\"" + weaponName + "\"; likely melee/PlyrArm path");
        }
        local proxy = EnsureWorldProxy(model);
        if(proxy == 0) return false;

        local off = ReadLiveOffset(vm);
        local localPos = vector(
            off.x + SS2FA_GetFloat("ss2fa_weapon_proxy_forward", 0.0),
            off.y + SS2FA_GetFloat("ss2fa_weapon_proxy_left", 0.0),
            off.z + SS2FA_GetFloat("ss2fa_weapon_proxy_up", 0.0)
        );
        HideNativeViewmodel(vm);

        local k = SS2FA_GetFloat("ss2fa_weapon_proxy_scale", 1.0);
        if(k <= 0.0) k = 1.0;
        try { Property.Set(proxy, "Scale", "", vector(k, k, k)); } catch(eS) {}

        local worldPos = Camera.CameraToWorld(localPos);
        local facingMode = SS2FA_GetInt("ss2fa_weapon_proxy_facing_mode", 0);
        // Use the same view-frame aim as the projectile so the gun and bullets agree and
        // neither pinches toward the poles. ss2fa_view_frame_aim=0 reverts to the DLL ray.
        local aimDir = vector(aim.wdx, aim.wdy, aim.wdz);
        if(SS2FA_GetInt("ss2fa_view_frame_aim", 1) != 0){
            aimDir = SS2FA_ViewFrameAim(aim.dyaw, aim.dpitch);
        }
        local proxyDir = aimDir;
        if(facingMode == 4 || facingMode == 5 || facingMode == 6 || facingMode == 7 || facingMode == 8 || facingMode == 9){
            local lookDistance = SS2FA_GetFloat("ss2fa_weapon_proxy_look_distance", 40.0);
            if(lookDistance < 1.0) lookDistance = 1.0;
            local target = vector(
                aim.wox + aimDir.x * lookDistance,
                aim.woy + aimDir.y * lookDistance,
                aim.woz + aimDir.z * lookDistance
            );
            proxyDir = SS2FA_NormalizeVec(
                vector(target.x - worldPos.x, target.y - worldPos.y, target.z - worldPos.z),
                aimDir
            );
        }
        SS2FA_ResetProxyBasis();
        local facing = null;
        if(facingMode == 9){
            facing = SS2FA_DirToProxyFacingViewRelative(proxyDir.x, proxyDir.y, proxyDir.z);
        } else if(facingMode == 8){
            // Mode 8 now runs the view-relative (screen-upright) path. The DLL clamps
            // facing_mode to <=8, so this is the highest mode that actually reaches Squirrel.
            facing = SS2FA_DirToProxyFacingViewRelative(proxyDir.x, proxyDir.y, proxyDir.z);
        } else if(facingMode == 7){
            EnsureProxyHeadingBaseline(proxyDir, false);
            facing = SS2FA_DirToProxyFacingRollKilled(proxyDir.x, proxyDir.y, proxyDir.z, m_proxyHeadingBaselineValid, m_proxyHeadingBaseline);
        } else if(facingMode == 6){
            EnsureProxyBaseline();
            facing = SS2FA_DirToProxyFacingWithUp(proxyDir.x, proxyDir.y, proxyDir.z, m_proxyBaselineUp, m_proxyBaselineRight);
        } else {
            facing = SS2FA_DirToProxyFacing(proxyDir.x, proxyDir.y, proxyDir.z);
        }
        // FIXED-FACING PROBE: bypass all computed facing to read KEX's true
        // facing->orientation directly (convention ground truth). Set
        // ss2fa_weapon_proxy_test_facing=1 and sweep test_bank/test_pitch/test_heading;
        // then watch the ACTUAL gun (independent of aim math and FacingBasis prediction).
        if(SS2FA_GetInt("ss2fa_weapon_proxy_test_facing", 0) != 0){
            facing = vector(
                SS2FA_GetFloat("ss2fa_weapon_proxy_test_bank", 0.0),
                SS2FA_GetFloat("ss2fa_weapon_proxy_test_pitch", 0.0),
                SS2FA_GetFloat("ss2fa_weapon_proxy_test_heading", 0.0)
            );
        }
        // WEAPON VIEWMODEL ROTATION TOGGLE: ss2fa_weapon_view_rotate=0 holds the gun
        // model in its neutral (screen-centered) pose so it does NOT swing with the
        // crosshair. Aim and projectiles are unaffected -- they use aimDir / the DLL aim,
        // not this facing. Reusing the view-centered facing means the pivot block below
        // cancels to zero (rotatedBasis == neutralBasis), so the gun also doesn't shift.
        if(SS2FA_GetInt("ss2fa_weapon_view_rotate", 1) == 0){
            local centeredAim = SS2FA_ViewFrameAim(0.0, 0.0);
            facing = SS2FA_DirToProxyFacingViewRelative(centeredAim.x, centeredAim.y, centeredAim.z);
        }
        // VIEW-PITCH ROLL COMPENSATION (the actual fix): the engine baked a roll into
        // the proxy = f(view pitch at creation). Subtract it back via the bank axis
        // (Shot 5 proved bank rolls about the barrel). Live-tunable scale; 0 = off.
        // Tune: enter Freelook while pitched, then sweep ss2fa_weapon_proxy_view_roll_comp
        // (try ~1.0 / -1.0) until the gun snaps upright. It then holds for any entry pitch.
        local viewRollComp = SS2FA.proxyViewPitchAtCreate
            * SS2FA_GetFloat("ss2fa_weapon_proxy_view_roll_comp", 0.0);
        if(viewRollComp != 0.0){
            facing = vector(facing.x + viewRollComp, facing.y, facing.z);
        }
        local baseWorldPos = worldPos;
        local basis = SS2FA_ProxyBasisForFacing(facing);
        local pivotApplied = 0;
        local pivotLocal = vector(0.0, 0.0, 0.0);
        local longProxyWeapon = SS2FA_IsLongProxyWeapon(weaponName, model);
        // Apply the shoulder/back pivot to ALL weapons by default (feels more consistent);
        // set ss2fa_weapon_proxy_pivot_all_weapons 0 to restrict it back to long weapons only.
        local pivotAllWeapons = SS2FA_GetInt("ss2fa_weapon_proxy_pivot_all_weapons", 1) != 0;
        if(SS2FA_GetInt("ss2fa_weapon_proxy_pivot_enable", 1) != 0 && (pivotAllWeapons || longProxyWeapon)){
            pivotLocal = vector(
                SS2FA_GetFloat("ss2fa_weapon_proxy_pivot_long_forward", -1.25),
                SS2FA_GetFloat("ss2fa_weapon_proxy_pivot_long_left", 0.0),
                SS2FA_GetFloat("ss2fa_weapon_proxy_pivot_long_up", 0.0)
            );
            if(SS2FA_VecLen(pivotLocal) > 0.0001){
                // Rotate-about-pivot must be computed in the gun's TRUE rendered frame.
                // The stored proxy basis (and FlatCameraScreenBasis) carry the ~180deg-off
                // view-frame forward -- the same reflection that sent raw projectile velocity
                // backward -- so using them here reversed the horizontal pivot term and made
                // the offset appear to swing with the player's heading. SS2FA_FacingBasis
                // inverts the engine's facing->forward, giving the real world orientation for
                // both the current aim and the centered (neutral) aim.
                local rotatedBasis = SS2FA_FacingBasis(facing);
                // Centered-aim facing reuses the gun pipeline; save/restore the proxy-basis
                // globals it writes so the muzzle/eject FX still read the CURRENT aim's basis.
                local savedFwd = SS2FA.proxyBasisForward;
                local savedRight = SS2FA.proxyBasisRight;
                local savedUp = SS2FA.proxyBasisUp;
                local savedRollRaw = SS2FA.proxyRollRaw;
                local savedRollApplied = SS2FA.proxyRollApplied;
                local savedRollSign = SS2FA.proxyRollSign;
                local savedRollKill = SS2FA.proxyRollKill;
                local centeredAim = SS2FA_ViewFrameAim(0.0, 0.0);
                local neutralFacing = SS2FA_DirToProxyFacingViewRelative(centeredAim.x, centeredAim.y, centeredAim.z);
                SS2FA.proxyBasisForward = savedFwd;
                SS2FA.proxyBasisRight = savedRight;
                SS2FA.proxyBasisUp = savedUp;
                SS2FA.proxyRollRaw = savedRollRaw;
                SS2FA.proxyRollApplied = savedRollApplied;
                SS2FA.proxyRollSign = savedRollSign;
                SS2FA.proxyRollKill = savedRollKill;
                local neutralBasis = SS2FA_FacingBasis(neutralFacing);
                local neutralOffset = SS2FA_ProxyLocalToWorldOffset(pivotLocal, neutralBasis);
                local rotatedOffset = SS2FA_ProxyLocalToWorldOffset(pivotLocal, rotatedBasis);
                worldPos = vector(
                    baseWorldPos.x + neutralOffset.x - rotatedOffset.x,
                    baseWorldPos.y + neutralOffset.y - rotatedOffset.y,
                    baseWorldPos.z + neutralOffset.z - rotatedOffset.z
                );
                pivotApplied = 1;
            }
        }
        SS2FA_DrawProxyBasis(worldPos, basis);
        local headingText = " hRaw=" + format("%.2f", SS2FA.proxyHeadingRaw)
            + " hOut=" + format("%.2f", SS2FA.proxyHeadingApplied)
            + " hBase=" + format("%.2f", SS2FA.proxyHeadingBase)
            + " flipX=" + SS2FA.proxyHeadingFlipX
            + " dark=" + SS2FA.proxyDarkMatrix;
        local pivotText = " weapon=\"" + weaponName + "\""
            + " long=" + (longProxyWeapon ? "1" : "0")
            + " pivot=" + pivotApplied
            + " pivotLocal=" + SS2FA_FormatVec(pivotLocal)
            + " baseWorld=" + SS2FA_FormatVec(baseWorldPos);
        local basisText = "";
        if(SS2FA_GetInt("ss2fa_weapon_proxy_axis_log", 0) != 0){
            basisText = " basisF=" + SS2FA_FormatVec(basis.forward)
                + " basisR=" + SS2FA_FormatVec(basis.right)
                + " basisU=" + SS2FA_FormatVec(basis.up);
        }

        try {
            Object.Teleport(proxy, worldPos, facing);
        } catch(eT) {
            ::print("[SS2FA-PROXY] teleport failed obj=" + proxy + " error=" + eT.tostring());
            SS2FA.proxyValid = false;
            return false;
        }
        SS2FA.proxyValid = true;
        SS2FA.proxyWorldPos = worldPos;
        SS2FA.proxyFacing = facing;

        local rendered = -1;
        try { rendered = Object.RenderedThisFrame(proxy) ? 1 : 0; } catch(eR) {}
        if(!m_worldProxyLogged && (SS2FA_GetInt("ss2fa_aim_log", 0) != 0 || SS2FA_GetInt("ss2fa_weapon_proxy_pose_log", 0) != 0)){
            m_worldProxyLogged = true;
            ::print("[SS2FA-PROXY] active obj=" + proxy
                + " native=" + vm
                + " model=" + model
                + " rendered=" + rendered
                + " local=(" + format("%.3f", localPos.x) + "," + format("%.3f", localPos.y) + "," + format("%.3f", localPos.z) + ")"
                + " world=(" + format("%.2f", worldPos.x) + "," + format("%.2f", worldPos.y) + "," + format("%.2f", worldPos.z) + ")"
                + pivotText
                + " facing=(" + format("%.2f", facing.x) + "," + format("%.2f", facing.y) + "," + format("%.2f", facing.z) + ")"
                + " dir=(" + format("%.3f", aim.wdx) + "," + format("%.3f", aim.wdy) + "," + format("%.3f", aim.wdz) + ")"
                + " proxyDir=(" + format("%.3f", proxyDir.x) + "," + format("%.3f", proxyDir.y) + "," + format("%.3f", proxyDir.z) + ")"
                + " rollRaw=" + format("%.2f", SS2FA.proxyRollRaw)
                + " rollApplied=" + format("%.2f", SS2FA.proxyRollApplied)
                + " rollSign=" + format("%.1f", SS2FA.proxyRollSign)
                + " rollKill=" + SS2FA.proxyRollKill
                + headingText
                + basisText
                + " scale=" + format("%.2f", k)
                + " hideNative=" + SS2FA_GetInt("ss2fa_weapon_proxy_hide_native", 1)
                + " facingMode=" + facingMode
                + (m_proxyBaselineValid ? (" basePitch=" + format("%.2f", m_proxyBaselinePitch)) : "")
                + " lookDist=" + format("%.1f", SS2FA_GetFloat("ss2fa_weapon_proxy_look_distance", 40.0)));
        }
        // Gun is solved; per-frame pose/VDBG spam is off by default now. Re-enable with
        // ss2fa_weapon_proxy_pose_log=1 only if the viewmodel needs revisiting.
        if(SS2FA_GetInt("ss2fa_weapon_proxy_pose_log", 0) != 0 && now - m_lastProxyPoseLogTime > 500){
            m_lastProxyPoseLogTime = now;
            ::print("[SS2FA-PROXY] pose obj=" + proxy
                + " facing=(" + format("%.2f", facing.x) + "," + format("%.2f", facing.y) + "," + format("%.2f", facing.z) + ")"
                + " dir=(" + format("%.3f", aim.wdx) + "," + format("%.3f", aim.wdy) + "," + format("%.3f", aim.wdz) + ")"
                + " proxyDir=(" + format("%.3f", proxyDir.x) + "," + format("%.3f", proxyDir.y) + "," + format("%.3f", proxyDir.z) + ")"
                + " rollRaw=" + format("%.2f", SS2FA.proxyRollRaw)
                + " rollApplied=" + format("%.2f", SS2FA.proxyRollApplied)
                + " rollSign=" + format("%.1f", SS2FA.proxyRollSign)
                + " rollKill=" + SS2FA.proxyRollKill
                + headingText
                + pivotText
                + basisText
                + " facingMode=" + facingMode
                + " createPitch=" + format("%.2f", SS2FA.proxyViewPitchAtCreate)
                + " viewRollComp=" + format("%.2f", SS2FA.proxyViewPitchAtCreate * SS2FA_GetFloat("ss2fa_weapon_proxy_view_roll_comp", 0.0))
                + (m_proxyBaselineValid ? (" basePitch=" + format("%.2f", m_proxyBaselinePitch)) : ""));
        }
        return true;
    }

    function ResolveCrosshairBitmap()
    {
        if(m_crosshairBitmap != null) return true;

        foreach(name in ["crosshai", "CROSSHAI"]){
            try {
                local bitmap = ShockOverlay.GetBitmap(name);
                local width = int_ref();
                local height = int_ref();
                ShockOverlay.GetBitmapSize(bitmap, width, height);
                m_crosshairBitmap = bitmap;
                m_crosshairBitmapName = name;
                m_crosshairBitmapW = width.tointeger();
                m_crosshairBitmapH = height.tointeger();
                if(m_crosshairBitmapW <= 0) m_crosshairBitmapW = 16;
                if(m_crosshairBitmapH <= 0) m_crosshairBitmapH = 16;
                return true;
            } catch(e) {}
        }

        if(!m_crosshairFailureLogged){
            m_crosshairFailureLogged = true;
            ::print("[SS2FA] native HUD reticle bitmap lookup failed for crosshai/CROSSHAI");
        }
        return false;
    }

    function DrawNativeHudReticle(aim)
    {
        if(SS2FA_GetInt("ss2fa_native_hud_reticle", 1) == 0) return;
        if(!SS2FA_GameplayHudMode()) return;
        if(!ResolveCrosshairBitmap()) return;

        // Measure the real overlay space first (no-op once calibrated for this resolution).
        SS2FA_CalibrateOverlaySpace();
        local reticle = SS2FA_ReticleOverlayPoint(aim);
        local originBiasScale = SS2FA_OverlayOriginBiasScale();
        local offsetX = SS2FA_GetFloat("ss2fa_native_hud_reticle_offset_x", 0.0).tointeger();
        local offsetY = SS2FA_GetFloat("ss2fa_native_hud_reticle_offset_y", 0.0).tointeger();
        local x = (reticle.x + 0.5).tointeger();
        local y = (reticle.y + 0.5).tointeger();
        local drawX = x - (m_crosshairBitmapW / 2);
        local drawY = y - (m_crosshairBitmapH / 2);

        try {
            ShockOverlay.DrawBitmap(
                m_crosshairBitmap,
                drawX,
                drawY
            );
            if(!m_crosshairActiveLogged && SS2FA_GetInt("ss2fa_aim_log", 0) != 0){
                m_crosshairActiveLogged = true;
                ::print("[SS2FA] native HUD reticle active bitmap=" + m_crosshairBitmapName
                    + " size=" + m_crosshairBitmapW + "x" + m_crosshairBitmapH
                    + " rawCanvas=" + reticle.rawX + "x" + reticle.rawY
                    + " hudCanvas=" + reticle.hudX + "x" + reticle.hudY
                    + " source=" + reticle.source
                    + " originBiasScale=" + format("%.3f", originBiasScale)
                    + " originBias=(" + format("%.2f", reticle.originBiasX) + "," + format("%.2f", reticle.originBiasY) + ")"
                    + " drawTopLeft=(" + drawX + "," + drawY + ")"
                    + " drawCenter=(" + x + "," + y + ")"
                    + " eid_hint=2812");
            }
            LogCrosshairDrawProbe(
                aim,
                reticle,
                x,
                y,
                drawX,
                drawY,
                offsetX,
                offsetY
            );
        } catch(e) {
            if(!m_crosshairFailureLogged){
                m_crosshairFailureLogged = true;
                ::print("[SS2FA] native HUD reticle draw failed: " + e.tostring());
            }
        }
    }

    function LogCrosshairDrawProbe(aim, reticle, x, y, drawX, drawY, offsetX, offsetY)
    {
        if(SS2FA_GetInt("ss2fa_crosshair_probe_log", SS2FA_GetInt("ss2fa_aim_log", 0)) == 0)
            return;
        local now = ShockGame.SimTime();
        local shouldLog = false;
        if(m_crosshairDiagSamples < 4){
            shouldLog = true;
        } else if(m_crosshairDiagSamples < 16 && now - m_crosshairDiagLastTime >= 1000){
            shouldLog = true;
        }
        if(!shouldLog) return;

        m_crosshairDiagSamples++;
        m_crosshairDiagLastTime = now;

        local centerHudX = reticle.hudX * 0.5;
        local centerHudY = reticle.hudY * 0.5;
        local errX = x - centerHudX;
        local errY = y - centerHudY;
        local scaleX = reticle.rawX.tofloat() / reticle.hudX.tofloat();
        local scaleY = reticle.rawY.tofloat() / reticle.hudY.tofloat();
        local predictedFinalX = (x + reticle.originBiasX) * scaleX;
        local predictedFinalY = (y + reticle.originBiasY) * scaleY;
        local desiredFinalX = aim.cu * (reticle.rawX - 1);
        local desiredFinalY = aim.cv * (reticle.rawY - 1);
        local projectText = "";
        if(reticle.projectPos != null){
            projectText = " projectDist=" + format("%.1f", reticle.projectDist)
                + " projectWorld=(" + format("%.2f", reticle.projectPos.x)
                + "," + format("%.2f", reticle.projectPos.y)
                + "," + format("%.2f", reticle.projectPos.z) + ")";
        }
        ::print("[SS2FA-XHAIR-PROBE] sample=" + m_crosshairDiagSamples
            + " aimCuv=(" + format("%.6f", aim.cu) + "," + format("%.6f", aim.cv) + ")"
            + " rawCanvas=" + reticle.rawX + "x" + reticle.rawY
            + " hudCanvas=" + reticle.hudX + "x" + reticle.hudY
            + " source=" + reticle.source
            + " targetMinusOne=(" + format("%.3f", reticle.targetMinusOneX) + "," + format("%.3f", reticle.targetMinusOneY) + ")"
            + " targetOverlay=(" + format("%.3f", reticle.targetOverlayX) + "," + format("%.3f", reticle.targetOverlayY) + ")"
            + " originBias=(" + format("%.3f", reticle.originBiasX) + "," + format("%.3f", reticle.originBiasY) + ")"
            + " scale=(" + format("%.3f", scaleX) + "," + format("%.3f", scaleY) + ")"
            + " predictedFinal=(" + format("%.3f", predictedFinalX) + "," + format("%.3f", predictedFinalY) + ")"
            + " desiredFinal=(" + format("%.3f", desiredFinalX) + "," + format("%.3f", desiredFinalY) + ")"
            + " hudCenter=(" + format("%.3f", centerHudX) + "," + format("%.3f", centerHudY) + ")"
            + " drawCenter=(" + x + "," + y + ")"
            + " centerErr=(" + format("%.3f", errX) + "," + format("%.3f", errY) + ")"
            + " bitmap=" + m_crosshairBitmapName + ":" + m_crosshairBitmapW + "x" + m_crosshairBitmapH
            + " topLeft=(" + drawX + "," + drawY + ")"
            + " offset=(" + offsetX + "," + offsetY + ")"
            + projectText);
    }

    function OnFrameUpdate(deltaTime)
    {
        local now = ShockGame.SimTime();
        if(now - m_lastAliveTime >= 250){
            SS2FA_PublishAlive();
            m_lastAliveTime = now;
        }
        if(SS2FA_GetInt("ss2fa_enable", 1) == 0){
            SetNativeCrosshairHidden(false);
            DestroyWorldProxy();
            return;
        }
        local aim = SS2FA_ReadAim();
        if(aim == null){
            SetNativeCrosshairHidden(false);
            DestroyWorldProxy();
            return;
        }
        try {
            if(!m_loggedAim){
                if(SS2FA_GetInt("ss2fa_aim_log", 0) != 0)
                    ::print("[SS2FA] ss2fa_aim bridge active");
                m_loggedAim = true;
            }
            if(SS2FA_GetInt("ss2fa_native_hud_hide_original", 1) != 0 && SS2FA_GameplayHudMode()){
                SetNativeCrosshairHidden(true);
            } else {
                SetNativeCrosshairHidden(false);
            }
            DrawNativeHudReticle(aim);

            local wh = SS2FA_FindWeaponHandler();
            if(wh == null) {
                if(!m_missingWeaponHandlerLogged){
                    if(SS2FA_GetInt("ss2fa_aim_log", 0) != 0)
                        ::print("[SS2FA] AimHandler could not find WeaponHandler");
                    m_missingWeaponHandlerLogged = true;
                }
                DestroyWorldProxy();
                return;
            }
            local vm = wh.m_viewmodelObject;
            if(!Object.Exists(vm)){
                DestroyWorldProxy();
                return;
            }
            if(m_lastViewmodelObject != vm){
                if(m_hiddenNativeObj != 0 || m_worldProxyObj != 0) DestroyWorldProxy();
                m_lastViewmodelObject = vm;
                m_baseOffset = null;
                m_baseOffsetObject = null;
                m_meleeRecreateTried = false;
                if(SS2FA_GetInt("ss2fa_aim_log", 0) != 0)
                    ::print("[SS2FA] AimHandler viewmodel object " + vm);
            }
            if(!Property.Possessed(vm, "CameraObj")) Property.Add(vm, "CameraObj");
            local dh = aim.dyaw   * SS2FA_GetFloat("ss2fa_weapon_heading_sign", 1.0);
            local dp = aim.dpitch * SS2FA_GetFloat("ss2fa_weapon_pitch_sign",  1.0);
            local db = SS2FA_GetFloat("ss2fa_weapon_bank_deg", 0.0);
            local mode = SS2FA_GetInt("ss2fa_weapon_follow_mode", 1);
            local off = null;
            local compText = "";
            if(mode != 7 && (m_worldProxyObj != 0 || m_hiddenNativeObj != 0)){
                DestroyWorldProxy();
            }
            if(mode == 7
                && SS2FA_GetInt("ss2fa_weapon_effect_follow", 1) != 0
                && SS2FA_GetInt("ss2fa_weapon_effect_recreate", 1) != 0
                && !SS2FA_IsMeleeEquipped(wh)
                && (("rigViewmodelInstalled" in SS2FA) && SS2FA.rigViewmodelInstalled)
                && (!(("effectViewmodelActive" in SS2FA) && SS2FA.effectViewmodelActive))
                && !m_effectRecreateTried
                && ("CreateViewmodelObject" in wh)
                && ("m_equippedWeapon" in wh)
                && Object.Exists(wh.m_equippedWeapon)){
                m_effectRecreateTried = true;
                try {
                    wh.CreateViewmodelObject(wh.m_equippedWeapon);
                    if(SS2FA_GetInt("ss2fa_weapon_effect_log", 0) != 0)
                        ::print("[SS2FA-FX] requested mode=7 viewmodel recreate weapon=" + wh.m_equippedWeapon);
                } catch(e) {
                    ::print("[SS2FA-FX] mode=7 viewmodel recreate failed: " + e.tostring());
                }
            }
            if(mode == 7 && SS2FA_IsMeleeEquipped(wh)){
                DestroyWorldProxy();
                local meleeFresh = (now - SS2FA.meleeViewmodelLastActiveTime) <= 750;
                if((("meleeViewmodelInstalled" in SS2FA) && SS2FA.meleeViewmodelInstalled)
                    && !meleeFresh
                    && !m_meleeRecreateTried
                    && ("CreateViewmodelObject" in wh)
                    && ("m_equippedWeapon" in wh)
                    && Object.Exists(wh.m_equippedWeapon)){
                    m_meleeRecreateTried = true;
                    try {
                        wh.CreateViewmodelObject(wh.m_equippedWeapon);
                        if(SS2FA_GetInt("ss2fa_melee_pose_log", 0) != 0)
                            ::print("[SS2FA-MELEE] requested melee viewmodel recreate weapon=" + wh.m_equippedWeapon);
                    } catch(e) {
                        ::print("[SS2FA-MELEE] melee viewmodel recreate failed: " + e.tostring());
                    }
                }
                if(SS2FA_GetInt("ss2fa_aim_log", 0) != 0 && now - m_lastWeaponLogTime > 1000){
                    m_lastWeaponLogTime = now;
                    ::print("[SS2FA] weapon CameraObj mode=7 meleeProxy=1 installed="
                        + ((("meleeViewmodelInstalled" in SS2FA) && SS2FA.meleeViewmodelInstalled) ? "1" : "0")
                        + " activeFresh=" + (meleeFresh ? "1" : "0")
                        + " viewmodel=" + vm
                        + " dh=" + format("%.2f", dh)
                        + " dp=" + format("%.2f", dp));
                }
                return;
            }
            if(mode == 5){
                if((("rigViewmodelInstalled" in SS2FA) && SS2FA.rigViewmodelInstalled)
                    && (!(("rigViewmodelActive" in SS2FA) && SS2FA.rigViewmodelActive))
                    && !m_mode5RecreateTried
                    && ("CreateViewmodelObject" in wh)
                    && ("m_equippedWeapon" in wh)
                    && Object.Exists(wh.m_equippedWeapon)){
                    m_mode5RecreateTried = true;
                    try {
                        wh.CreateViewmodelObject(wh.m_equippedWeapon);
                        if(SS2FA_GetInt("ss2fa_aim_log", 0) != 0)
                            ::print("[SS2FA-RIG] requested mode=5 viewmodel recreate weapon=" + wh.m_equippedWeapon);
                    } catch(e) {
                        ::print("[SS2FA-RIG] mode=5 viewmodel recreate failed: " + e.tostring());
                    }
                }
                if(SS2FA_GetInt("ss2fa_aim_log", 0) != 0 && now - m_lastWeaponLogTime > 1000){
                    m_lastWeaponLogTime = now;
                    ::print("[SS2FA] weapon CameraObj mode=5 external_skip=1 rigInstalled="
                        + ((("rigViewmodelInstalled" in SS2FA) && SS2FA.rigViewmodelInstalled) ? "1" : "0")
                        + " rigActive=" + ((("rigViewmodelActive" in SS2FA) && SS2FA.rigViewmodelActive) ? "1" : "0")
                        + " dh=" + format("%.2f", dh)
                        + " dp=" + format("%.2f", dp));
                }
                return;
            }
            if(mode == 7){
                local proxyApplied = ApplyWorldProxy(vm, aim, now, wh);
                if(SS2FA_GetInt("ss2fa_aim_log", 0) != 0 && now - m_lastWeaponLogTime > 1000){
                    m_lastWeaponLogTime = now;
                    ::print("[SS2FA] weapon CameraObj mode=7 worldProxy=1 applied=" + (proxyApplied ? "1" : "0")
                        + " nativeHidden=" + ((m_hiddenNativeObj == vm) ? "1" : "0")
                        + " proxyObj=" + m_worldProxyObj
                        + " dh=" + format("%.2f", dh)
                        + " dp=" + format("%.2f", dp)
                        + " ray=(" + format("%.3f", aim.wdx) + "," + format("%.3f", aim.wdy) + "," + format("%.3f", aim.wdz) + ")"
                        + " facingMode=" + SS2FA_GetInt("ss2fa_weapon_proxy_facing_mode", 0));
                }
                return;
            }
            if(mode == 2){
                local baseOff = CaptureBaseOffset(vm);
                local left = aim.dyaw * SS2FA_GetFloat("ss2fa_weapon_offset_left_per_deg", -0.015);
                local up = aim.dpitch * SS2FA_GetFloat("ss2fa_weapon_offset_up_per_deg", 0.015);
                local forward = SS2FA_GetFloat("ss2fa_weapon_offset_forward", 0.0);
                off = vector(baseOff.x + forward, baseOff.y + left, baseOff.z + up);
                dh = 0.0;
                dp = 0.0;
                db = 0.0;
                Property.Set(vm, "CameraObj", "Offset", off);
            } else if(mode == 3){
                local camPitch = 0.0;
                try { camPitch = SS2FA_SignedAngleDeg(Camera.GetFacing().y); } catch(e) {}
                local pitchRad = camPitch * SS2FA_PI / 180.0;
                local cosPitch = cos(pitchRad);
                if(cosPitch < 0.0) cosPitch = -cosPitch;
                local sinPitch = sin(pitchRad);
                local headingScale = SS2FA_GetFloat("ss2fa_weapon_pitch_comp_heading_scale", 1.0);
                local bankSign = SS2FA_GetFloat("ss2fa_weapon_pitch_comp_bank_sign", -1.0);
                local rawHeading = dh;
                dh = rawHeading * (1.0 + ((cosPitch - 1.0) * headingScale));
                db += rawHeading * sinPitch * bankSign;
                compText = " camPitch=" + format("%.2f", camPitch)
                    + " cos=" + format("%.3f", cosPitch)
                    + " sin=" + format("%.3f", sinPitch)
                    + " rawH=" + format("%.2f", rawHeading)
                    + " hScale=" + format("%.2f", headingScale)
                    + " bankSign=" + format("%.2f", bankSign);
            } else if(mode == 6){
                local camPitch = 0.0;
                try { camPitch = SS2FA_SignedAngleDeg(Camera.GetFacing().y); } catch(e) {}
                local pitchRad = camPitch * SS2FA_PI / 180.0;
                local cosPitch = cos(pitchRad);
                local absCos = cosPitch;
                if(absCos < 0.0) absCos = -absCos;
                local sinPitch = sin(pitchRad);
                local rawHeading = dh;
                local bankSign = SS2FA_GetFloat("ss2fa_weapon_pitch_comp_bank_sign", -1.0);
                local variant = SS2FA_GetInt("ss2fa_weapon_screen_axis_variant", 0);
                if(variant < 0 || variant > 4) variant = 0;
                local hAxis = 0.0;
                local bAxis = 0.0;
                local variantName = "cos_heading_sin_bank";

                if(variant == 0){
                    hAxis = rawHeading * absCos;
                    bAxis = rawHeading * sinPitch * bankSign;
                } else if(variant == 1){
                    variantName = "cos_heading_inv_sin_bank";
                    hAxis = rawHeading * absCos;
                    bAxis = rawHeading * sinPitch * bankSign * -1.0;
                } else if(variant == 2){
                    variantName = "cos_heading_only";
                    hAxis = rawHeading * absCos;
                    bAxis = 0.0;
                } else if(variant == 3){
                    variantName = "sin_bank_only";
                    hAxis = 0.0;
                    bAxis = rawHeading * sinPitch * bankSign;
                } else {
                    variantName = "sin_heading_cos_bank";
                    hAxis = rawHeading * sinPitch;
                    bAxis = rawHeading * absCos * bankSign;
                }

                dh = hAxis;
                db += bAxis;
                compText = " screenAxis=1 variant=" + variant
                    + "(" + variantName + ")"
                    + " camPitch=" + format("%.2f", camPitch)
                    + " cos=" + format("%.3f", cosPitch)
                    + " absCos=" + format("%.3f", absCos)
                    + " sin=" + format("%.3f", sinPitch)
                    + " rawH=" + format("%.2f", rawHeading)
                    + " hAxis=" + format("%.2f", hAxis)
                    + " bAxis=" + format("%.2f", bAxis)
                    + " bankSign=" + format("%.2f", bankSign);
            } else if(mode == 4){
                local camPitch = 0.0;
                try { camPitch = SS2FA_SignedAngleDeg(Camera.GetFacing().y); } catch(e) {}
                local pitchRad = camPitch * SS2FA_PI / 180.0;
                local cosPitch = cos(pitchRad);
                local absCos = cosPitch;
                if(absCos < 0.0) absCos = -absCos;
                local minCos = SS2FA_GetFloat("ss2fa_weapon_screen_min_cos", 0.25);
                if(minCos < 0.05) minCos = 0.05;
                if(minCos > 1.0) minCos = 1.0;
                local rotScale = (absCos - minCos) / (1.0 - minCos);
                if(rotScale < 0.0) rotScale = 0.0;
                if(rotScale > 1.0) rotScale = 1.0;
                local sinPitch = sin(pitchRad);
                local rawHeading = dh;
                local headingComp = rawHeading * rotScale;
                local bankSign = SS2FA_GetFloat("ss2fa_weapon_pitch_comp_bank_sign", -1.0);
                local bankCancel = headingComp * sinPitch * bankSign;
                local offBlend = 1.0 - rotScale;
                local baseOff = CaptureBaseOffset(vm);
                local lateral = aim.dyaw * SS2FA_GetFloat("ss2fa_weapon_offset_left_per_deg", -0.015) * offBlend;
                local forward = SS2FA_GetFloat("ss2fa_weapon_offset_forward", 0.0);
                off = vector(baseOff.x + forward, baseOff.y + lateral, baseOff.z);
                Property.Set(vm, "CameraObj", "Offset", off);
                dh = headingComp;
                db += bankCancel;
                compText = " screenLocal=1 hybrid=1 camPitch=" + format("%.2f", camPitch)
                    + " cos=" + format("%.3f", cosPitch)
                    + " minCos=" + format("%.3f", minCos)
                    + " sin=" + format("%.3f", sinPitch)
                    + " rawH=" + format("%.2f", rawHeading)
                    + " hComp=" + format("%.2f", headingComp)
                    + " bCancel=" + format("%.2f", bankCancel)
                    + " bankSign=" + format("%.2f", bankSign)
                    + " rotScale=" + format("%.3f", rotScale)
                    + " offBlend=" + format("%.3f", offBlend)
                    + " lateral=" + format("%.3f", lateral);
            }
            local lockHeading = SS2FA_GetInt("ss2fa_weapon_lock_heading", 0) != 0;
            local lockPitch = SS2FA_GetInt("ss2fa_weapon_lock_pitch", 0) != 0;
            local lockBank = SS2FA_GetInt("ss2fa_weapon_lock_bank", 1) != 0;
            Property.Set(vm, "CameraObj", "Heading", SS2FA_DegToDark(dh));
            Property.Set(vm, "CameraObj", "Pitch",   SS2FA_DegToDark(dp));
            Property.Set(vm, "CameraObj", "Bank",    SS2FA_DegToDark(db));
            Property.Set(vm, "CameraObj", "Lock Heading?", lockHeading);
            Property.Set(vm, "CameraObj", "Lock Pitch?",   lockPitch);
            Property.Set(vm, "CameraObj", "Lock Bank?",    lockBank);
            if(SS2FA_GetInt("ss2fa_aim_log", 0) != 0 && now - m_lastWeaponLogTime > 1000){
                m_lastWeaponLogTime = now;
                ::print("[SS2FA] weapon CameraObj mode=" + mode
                    + " dh=" + format("%.2f", dh)
                    + " dp=" + format("%.2f", dp)
                    + " db=" + format("%.2f", db)
                    + compText
                    + ((off != null) ? (" off=(" + format("%.3f", off.x) + "," + format("%.3f", off.y) + "," + format("%.3f", off.z) + ")") : "")
                    + " lock=(" + (lockHeading ? "1" : "0") + "," + (lockPitch ? "1" : "0") + "," + (lockBank ? "1" : "0") + ")");
            }
        } catch(e) {
            if(SS2FA_GetInt("ss2fa_aim_log", 0) != 0) ::print("[SS2FA] weapon-follow skipped: " + e.tostring());
        }
    }
}

function SS2FA_FindWeaponHandler()
{
    foreach(handler in ND.g_PlayerCore.m_handlers){
        if(("m_name" in handler) && handler.m_name == "WeaponHandler"){
            return handler;
        }
    }
    return null;
}

//----------------------------------------------------------------------------
//  Crosshair draw at (cu,cv)
//  Implemented in AimHandler via ShockOverlay.DrawBitmap("crosshai"/"CROSSHAI")
//  while native overlay 22 is hidden.
//----------------------------------------------------------------------------

//----------------------------------------------------------------------------
//  Boot
//----------------------------------------------------------------------------
::print("[SS2FA] ss2fa.nut loaded rev=" + SS2FA_SCRIPT_REV);
SS2FA_PublishAlive();
SS2FA_ClearAim();
SS2FA_InstallRigViewmodelProbe();
SS2FA_InstallMeleeViewmodelProbe();
SS2FA_InstallProjectileScript();
try {
    local h = SS2FA.AimHandler();
    ND.g_PlayerCore.AddHandler(h);
} catch(e) { ::print("[SS2FA] AimHandler registration skipped: " + e.tostring()); }
try {
    local s = SS2FA.SelectionHandler();
    ND.g_PlayerCore.AddHandler(s);
} catch(e) { ::print("[SS2FA-SEL] SelectionHandler registration skipped: " + e.tostring()); }
