#!/bin/bash
# Unit tests for the parsing and classification logic. No hardware, no root.
#   ./tests/run.sh
set -uo pipefail
cd "$(dirname "$0")/.."

POWERBANK_LPM_LIB=1
POWERBANK_LPM_CONFIG=/nonexistent
export POWERBANK_LPM_LIB POWERBANK_LPM_CONFIG
# shellcheck disable=SC1091
. ./bin/powerbank-lpm

pass=0; fail=0
check() { # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
    else fail=$((fail+1)); printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; fi
}

# Real AdapterDetails captured from a 60 W third-party USB-C PD charger.
PD60='"IsWireless"=No,"AdapterID"=0,"AdapterVoltage"=20000,"FamilyCode"=18446744073172697098,"AdapterPowerTier"=2,"Watts"=60,"UsbHvcHvcIndex"=4,"Current"=3000,"UsbHvcMenu"=({"Index"=0,"MaxCurrent"=3000,"MaxVoltage"=5000}),"Description"="pd charger"'
# Apple 96 W brick: carries the identity fields third-party units omit.
APPLE96='"IsWireless"=No,"AdapterID"=16,"FamilyCode"=3741319180,"Watts"=96,"Manufacturer"="Apple Inc.","SerialString"="C4K1234567890ABCD","Description"="usb power adapter"'

echo "adapter_field"
check "bare numeric"           "60"                 "$(printf '%s' "$PD60"    | adapter_field Watts)"
check "quoted string"          "pd charger"         "$(printf '%s' "$PD60"    | adapter_field Description)"
check "absent key is empty"    ""                   "$(printf '%s' "$PD60"    | adapter_field SerialString)"
check "first match not nested" "16"                 "$(printf '%s' "$APPLE96" | adapter_field AdapterID)"
check "serial when present"    "C4K1234567890ABCD"  "$(printf '%s' "$APPLE96" | adapter_field SerialString)"
# Watts appears before nested MaxCurrent values; the parser must not run past it.
check "stops at delimiter"     "0"                  "$(printf '%s' "$PD60"    | adapter_field AdapterID)"

echo "adapter_fingerprint"
check "third-party tuple" "w=60;id=0;fc=18446744073172697098;sn=" "$(adapter_fingerprint "$PD60")"
check "apple tuple"       "w=96;id=16;fc=3741319180;sn=C4K1234567890ABCD" "$(adapter_fingerprint "$APPLE96")"
adapter_fingerprint "" >/dev/null 2>&1
check "empty input fails" "1" "$?"

echo "is_power_bank"
BANK_FINGERPRINTS="w=60;id=0;fc=18446744073172697098;sn="
BANK_MAX_WATTS=""
is_power_bank "$(adapter_fingerprint "$PD60")" 60;    check "allowlisted matches"      "0" "$?"
is_power_bank "$(adapter_fingerprint "$APPLE96")" 96; check "unlisted does not match"  "1" "$?"

BANK_FINGERPRINTS=""
BANK_MAX_WATTS="65"
is_power_bank "x" 60;  check "wattage fallback under"  "0" "$?"
is_power_bank "x" 96;  check "wattage fallback over"   "1" "$?"
is_power_bank "x" 65;  check "wattage fallback equal"  "0" "$?"
is_power_bank "x" "";  check "empty watts no match"    "1" "$?"
is_power_bank "x" "abc"; check "junk watts no match"   "1" "$?"

BANK_MAX_WATTS=""
is_power_bank "x" 5;   check "fallback disabled"       "1" "$?"

# An empty line in the config must not match an unparseable (empty) fingerprint.
BANK_FINGERPRINTS="
"
is_power_bank "" ""; check "blank config line inert" "1" "$?"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
