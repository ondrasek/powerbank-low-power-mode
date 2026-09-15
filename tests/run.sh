#!/bin/bash
# Unit tests for parsing, PD decoding and classification. No hardware, no root.
set -uo pipefail
cd "$(dirname "$0")/.."

POWERBANK_LPM_LIB=1
POWERBANK_LPM_CONFIG=/nonexistent
export POWERBANK_LPM_LIB POWERBANK_LPM_CONFIG
# shellcheck disable=SC1091
. ./bin/powerbank-lpm

pass=0; fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
    else fail=$((fail+1)); printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; fi
}

# Captured from a real 60 W third-party USB-C PD wall charger.
PD60='"IsWireless"=No,"AdapterID"=0,"AdapterVoltage"=20000,"FamilyCode"=18446744073172697098,"Watts"=60,"Description"="pd charger"'
APPLE96='"IsWireless"=No,"AdapterID"=16,"FamilyCode"=3741319180,"Watts"=96,"Manufacturer"="Apple Inc.","SerialString"="C4K1234567890ABCD"'
# Real advertised capabilities of that charger: 5/9/12/15/20V @3A + PPS.
# First PDO has unconstrained_power=1 -> mains-backed.
WALL_PDO='159486252,184620,246060,307500,409900,18446744072797564220,0,0,0,0,0,0,0'
# Same rails with bit 27 cleared and bit 29 (dual-role power) set: a battery-backed
# source, which is what a spec-compliant power bank advertises.
BANK_PDO=$(( (159486252 & ~(1<<27)) | (1<<29) ))",184620,246060,307500,409900,0,0,0,0,0,0,0,0"

echo "adapter_field"
check "bare numeric"        "60"                "$(printf '%s' "$PD60"    | adapter_field Watts)"
check "quoted string"       "pd charger"        "$(printf '%s' "$PD60"    | adapter_field Description)"
check "absent key empty"    ""                  "$(printf '%s' "$PD60"    | adapter_field SerialString)"
check "serial present"      "C4K1234567890ABCD" "$(printf '%s' "$APPLE96" | adapter_field SerialString)"

echo "pd_decode_one"
check "5V fixed rail"   "fixed      5000mV  3000mA  dual_role_power=0 unconstrained_power=1" "$(pd_decode_one 159486252)"
check "20V fixed rail"  "fixed     20000mV  3000mA  dual_role_power=0 unconstrained_power=0" "$(pd_decode_one 409900)"
check "pps apdo"        "pps        4500mV-21000mV 3000mA"                                   "$(pd_decode_one 18446744072797564220)"
check "decodes all"     "6" "$(pd_decode_all "$WALL_PDO" | wc -l | tr -d ' ')"
check "skips zeros"     "5" "$(pd_decode_all "$BANK_PDO" | wc -l | tr -d ' ')"

echo "pd_flags"
check "wall: unconstrained set"   "0 1" "$(pd_flags "$WALL_PDO")"
check "bank: unconstrained clear" "1 0" "$(pd_flags "$BANK_PDO")"
pd_flags "" >/dev/null 2>&1;        check "empty list fails"  "1" "$?"
pd_flags "0,0,0" >/dev/null 2>&1;   check "all-zero fails"    "1" "$?"
# A non-fixed first PDO would misdecode flags from unrelated bits.
pd_flags "18446744072797564220" >/dev/null 2>&1; check "non-fixed first PDO rejected" "1" "$?"

echo "pd_pdo_hash / fingerprint"
check "hash is stable"    "$(pd_pdo_hash "$WALL_PDO")" "$(pd_pdo_hash "$WALL_PDO")"
check "hash discriminates" "different" \
    "$([ "$(pd_pdo_hash "$WALL_PDO")" != "$(pd_pdo_hash "$BANK_PDO")" ] && echo different || echo same)"
check "fingerprint shape" "w=60;pdo=$(pd_pdo_hash "$WALL_PDO");sn=" "$(adapter_fingerprint "$PD60" "$WALL_PDO")"
adapter_fingerprint "" "" >/dev/null 2>&1; check "no adapter fails" "1" "$?"

echo "pd_pdo_list (stale-data guard)"
# PortControllerPortPDO persists after unplug; only a live contract (MaxPower>0)
# may be used. A port block with MaxPower=0 must yield nothing.
LIVE='"PortControllerPortPDO"=(159486252,184620),"PortControllerMaxPower"=60000}'
STALE='"PortControllerPortPDO"=(159486252,184620),"PortControllerMaxPower"=0}'
check "reads live port"  "159486252,184620" "$(pd_pdo_list "$LIVE")"
check "stale still parses if forced" "159486252,184620" "$(pd_pdo_list "$STALE")"
check "no match empty"   ""                 "$(pd_pdo_list "")"

echo "pd_device_id / pd_id_header"
# Real Discover Identity response from a 100 W Anker power bank.
META='"Metadata" = {"Product ID"=63077,"Vendor ID"=1204,"VDO Count"=4,"bcdDevice"=0,"VDOs"=(<b4048019>,<00000000>,<000065f6>,<00000000>)}'
check "vid:pid as hex" "04b4:f665" "$(pd_device_id "$META")"
pd_device_id "" >/dev/null 2>&1; check "no metadata fails" "1" "$?"
pd_device_id '"Metadata" = {"VDO Count"=0}' >/dev/null 2>&1; check "missing ids fails" "1" "$?"
# ioreg prints VDO bytes little-endian: <b4048019> is 0x198004b4.
check "id header decode" "ufp_product_type=3 dfp_product_type=3 modal=0 usb_host=0 usb_device=0" "$(pd_id_header "$META")"
pd_id_header '"Metadata" = {"VDOs"=(<b404>)}' >/dev/null 2>&1; check "short VDO rejected" "1" "$?"

echo "classify"
BANK_DEVICES=""; WALL_DEVICES=""; BANK_FINGERPRINTS=""; WALL_FINGERPRINTS=""
USE_PD_UNCONSTRAINED="0"; REQUIRE_DUAL_ROLE="0"; BANK_MAX_WATTS=""

classify fp "04b4:f665" 100 "" >/dev/null; check "unknown device rejected" "1" "$?"
BANK_DEVICES="04b4:f665"
classify fp "04b4:f665" 100 "" >/dev/null; check "listed device is a bank" "0" "$?"
classify fp "04b4:0000" 100 "" >/dev/null; check "other device unmatched"  "1" "$?"
# The real bank reports unconstrained_power=1; an explicit listing must still win.
classify fp "04b4:f665" 100 "$(pd_flags "$WALL_PDO")" >/dev/null
check "device list beats pd bits" "0" "$?"
WALL_DEVICES="04b4:f665"
classify fp "04b4:f665" 100 "$(pd_flags "$BANK_PDO")" >/dev/null
check "wall device wins over bank device" "1" "$?"
BANK_DEVICES=""; WALL_DEVICES=""

BANK_FINGERPRINTS="w=60;pdo=abc;sn="
classify "w=60;pdo=abc;sn=" "" 60 "" >/dev/null;  check "fingerprint fallback" "0" "$?"
BANK_DEVICES="04b4:f665"; WALL_FINGERPRINTS="w=60;pdo=abc;sn="
classify "w=60;pdo=abc;sn=" "04b4:f665" 60 "" >/dev/null
check "device id outranks fingerprint" "0" "$?"
BANK_DEVICES=""; BANK_FINGERPRINTS=""; WALL_FINGERPRINTS=""

USE_PD_UNCONSTRAINED="1"
classify fp "" 60 "$(pd_flags "$BANK_PDO")" >/dev/null; check "pd bit: bank"  "0" "$?"
classify fp "" 60 "$(pd_flags "$WALL_PDO")" >/dev/null; check "pd bit: wall"  "1" "$?"
REQUIRE_DUAL_ROLE="1"
classify fp "" 60 "0 0" >/dev/null; check "strict: needs dual-role"  "1" "$?"
classify fp "" 60 "1 0" >/dev/null; check "strict: dual-role passes" "0" "$?"
REQUIRE_DUAL_ROLE="0"; USE_PD_UNCONSTRAINED="0"
# Default config must not classify on the bit alone.
classify fp "" 60 "$(pd_flags "$BANK_PDO")" >/dev/null; check "pd bit ignored by default" "1" "$?"

BANK_MAX_WATTS="65"
classify fp "" 60 "" >/dev/null;    check "wattage fallback under" "0" "$?"
classify fp "" 96 "" >/dev/null;    check "wattage fallback over"  "1" "$?"
classify fp "" "" "" >/dev/null;    check "empty watts no match"   "1" "$?"
classify fp "" "abc" "" >/dev/null; check "junk watts no match"    "1" "$?"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
