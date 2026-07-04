#!/usr/bin/env bash
#
# check-legion-go-2.sh
#
# Read-only compatibility checker for running SimpleDeckyTDP's Lenovo WMI TDP
# path on the Lenovo Legion Go 2 (Ryzen Z2 Extreme).
#
# Usage:
#   bash scripts/check-legion-go-2.sh              # read-only checks (safe)
#   sudo bash scripts/check-legion-go-2.sh --write-test   # also does a single
#                                                         # safe write+restore
#
# The default run touches nothing. --write-test performs ONE conservative TDP
# write (to the driver-reported minimum) and then restores the original value
# and platform profile, to prove that WMI writes actually stick.

set -u

# ----------------------------------------------------------------------------
# output helpers
# ----------------------------------------------------------------------------

if [ -t 1 ]; then
  C_RESET="\033[0m"; C_GREEN="\033[32m"; C_YELLOW="\033[33m"; C_RED="\033[31m"; C_BOLD="\033[1m"
else
  C_RESET=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_BOLD=""
fi

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

pass()  { printf "  [${C_GREEN}PASS${C_RESET}] %s\n" "$1"; PASS_COUNT=$((PASS_COUNT + 1)); }
warn()  { printf "  [${C_YELLOW}WARN${C_RESET}] %s\n" "$1"; WARN_COUNT=$((WARN_COUNT + 1)); }
fail()  { printf "  [${C_RED}FAIL${C_RESET}] %s\n" "$1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
info()  { printf "         %s\n" "$1"; }
header(){ printf "\n${C_BOLD}%s${C_RESET}\n" "$1"; }

read_file() {
  # read_file <path> -> echoes trimmed contents or empty string
  if [ -r "$1" ]; then
    tr -d '\0' < "$1" 2>/dev/null | head -n1 | sed 's/[[:space:]]*$//'
  fi
}

# ----------------------------------------------------------------------------
# arg parsing
# ----------------------------------------------------------------------------

WRITE_TEST=0
for arg in "$@"; do
  case "$arg" in
    --write-test) WRITE_TEST=1 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      printf "Unknown argument: %s (use --help)\n" "$arg" >&2
      exit 2
      ;;
  esac
done

printf "${C_BOLD}SimpleDeckyTDP - Legion Go 2 compatibility check${C_RESET}\n"

# ----------------------------------------------------------------------------
# 1. Device identity
# ----------------------------------------------------------------------------

header "1. Device identity"

PRODUCT_NAME=$(read_file /sys/devices/virtual/dmi/id/product_name)
PRODUCT_VERSION=$(read_file /sys/devices/virtual/dmi/id/product_version)
SYS_VENDOR=$(read_file /sys/devices/virtual/dmi/id/sys_vendor)

info "product_name    : ${PRODUCT_NAME:-<unreadable>}"
info "product_version : ${PRODUCT_VERSION:-<unreadable>}"
info "sys_vendor      : ${SYS_VENDOR:-<unreadable>}"

case "$PRODUCT_NAME" in
  83N0|83N1)
    pass "Recognized Legion Go 2 product_name ($PRODUCT_NAME)"
    ;;
  83E1|83L3|83N6)
    warn "This is a Legion Go / Go S ($PRODUCT_NAME), not a Go 2 - already supported by the plugin"
    ;;
  "")
    fail "Could not read product_name"
    ;;
  *)
    warn "Unexpected product_name '$PRODUCT_NAME' - if this is a Legion Go 2, add it to is_legion_go() in py_modules/device_utils.py"
    ;;
esac

if [ "$SYS_VENDOR" = "LENOVO" ]; then
  pass "Vendor is LENOVO"
else
  warn "sys_vendor is '${SYS_VENDOR:-<unreadable>}' (expected LENOVO)"
fi

# ----------------------------------------------------------------------------
# 2. CPU + kernel
# ----------------------------------------------------------------------------

header "2. CPU and kernel"

CPU_VENDOR=$(grep -m1 '^vendor_id' /proc/cpuinfo 2>/dev/null | sed 's/.*:\s*//')
CPU_MODEL=$(grep -m1 '^model name' /proc/cpuinfo 2>/dev/null | sed 's/.*:\s*//')
KERNEL=$(uname -r)

info "cpu vendor : ${CPU_VENDOR:-<unknown>}"
info "cpu model  : ${CPU_MODEL:-<unknown>}"
info "kernel     : ${KERNEL}"

if [ "$CPU_VENDOR" = "AuthenticAMD" ]; then
  pass "AMD CPU detected"
else
  warn "CPU vendor is '${CPU_VENDOR:-<unknown>}' (expected AuthenticAMD for the Z2 Extreme)"
fi

# kernel version check: lenovo-wmi-other/-gamezone drivers landed ~6.16
KERNEL_MAJOR=$(printf '%s' "$KERNEL" | cut -d. -f1)
KERNEL_MINOR=$(printf '%s' "$KERNEL" | cut -d. -f2)
if [ -n "$KERNEL_MAJOR" ] && [ -n "$KERNEL_MINOR" ]; then
  if [ "$KERNEL_MAJOR" -gt 6 ] 2>/dev/null || { [ "$KERNEL_MAJOR" -eq 6 ] 2>/dev/null && [ "$KERNEL_MINOR" -ge 16 ] 2>/dev/null; }; then
    pass "Kernel $KERNEL is new enough for the lenovo-wmi drivers (>= 6.16)"
  else
    warn "Kernel $KERNEL may predate the lenovo-wmi-other/-gamezone drivers (want >= 6.16); WMI TDP may be unavailable"
  fi
else
  warn "Could not parse kernel version '$KERNEL'"
fi

# ----------------------------------------------------------------------------
# 3. WMI TDP attributes (lenovo-wmi-other)
# ----------------------------------------------------------------------------

header "3. WMI TDP attributes (lenovo-wmi-other)"

FW_ATTR_BASE="/sys/class/firmware-attributes"
WMI_DIR=""

# the plugin hardcodes 'lenovo-wmi-other-0'; also probe the non-suffixed name
for candidate in "$FW_ATTR_BASE/lenovo-wmi-other-0" "$FW_ATTR_BASE/lenovo-wmi-other"; do
  if [ -d "$candidate/attributes" ]; then
    WMI_DIR="$candidate/attributes"
    if [ "$(basename "$candidate")" = "lenovo-wmi-other-0" ]; then
      pass "Found WMI attributes at $candidate/attributes (matches plugin's hardcoded path)"
    else
      warn "Found WMI attributes at $candidate/attributes - plugin hardcodes 'lenovo-wmi-other-0'; LENOVO_WMI_PATH in py_modules/devices/lenovo.py would need adjusting"
    fi
    break
  fi
done

if [ -z "$WMI_DIR" ]; then
  fail "No lenovo-wmi-other attributes directory found under $FW_ATTR_BASE"
  info "Without this, the plugin falls back to ryzenadj instead of WMI TDP"
else
  for attr in ppt_pl1_spl ppt_pl2_sppt ppt_pl3_fppt; do
    if [ -d "$WMI_DIR/$attr" ]; then
      cur=$(read_file "$WMI_DIR/$attr/current_value")
      mn=$(read_file "$WMI_DIR/$attr/min_value")
      mx=$(read_file "$WMI_DIR/$attr/max_value")
      if [ "$cur" = "0" ]; then
        warn "$attr present but current_value reads 0 (known firmware bug on some units) [min=$mn max=$mx]"
      else
        pass "$attr present [current=$cur min=$mn max=$mx]"
      fi
    else
      fail "$attr missing under $WMI_DIR"
    fi
  done
fi

# ----------------------------------------------------------------------------
# 4. Platform profile (lenovo-wmi-gamezone, must expose 'custom')
# ----------------------------------------------------------------------------

header "4. Platform profile (lenovo-wmi-gamezone)"

GZ_DIR=""
if [ -d /sys/class/platform-profile ]; then
  for d in /sys/class/platform-profile/*/; do
    [ -d "$d" ] || continue
    name=$(read_file "$d/name")
    if [ "$name" = "lenovo-wmi-gamezone" ]; then
      GZ_DIR="$d"
      break
    fi
  done
fi

if [ -n "$GZ_DIR" ]; then
  pass "Found lenovo-wmi-gamezone platform profile at $GZ_DIR"
  choices=$(read_file "${GZ_DIR}choices")
  info "available profiles: ${choices:-<none>}"
  cur_profile=$(read_file "${GZ_DIR}profile")
  info "current profile   : ${cur_profile:-<unknown>}"
  case " $choices " in
    *" custom "*) pass "'custom' profile is available (required for WMI TDP writes)" ;;
    *) fail "'custom' profile NOT listed; the driver rejects TDP writes outside custom mode" ;;
  esac
else
  # fall back to the legacy acpi endpoint for information only
  acpi_choices=$(read_file /sys/firmware/acpi/platform_profile_choices)
  if [ -n "$acpi_choices" ]; then
    warn "No lenovo-wmi-gamezone class entry found; /sys/firmware/acpi/platform_profile_choices = $acpi_choices"
  else
    fail "No lenovo-wmi-gamezone platform profile found"
  fi
fi

# ----------------------------------------------------------------------------
# 5. GPU controls (amdgpu)
# ----------------------------------------------------------------------------

header "5. GPU controls (amdgpu)"

OD_PATH=$(ls /sys/class/drm/card*/device/pp_od_clk_voltage 2>/dev/null | head -n1)
LEVEL_PATH=$(ls /sys/class/drm/card*/device/power_dpm_force_performance_level 2>/dev/null | head -n1)

if [ -n "$OD_PATH" ]; then
  pass "Found pp_od_clk_voltage ($OD_PATH)"
  if grep -q 'OD_RANGE:' "$OD_PATH" 2>/dev/null && grep -A3 'OD_RANGE:' "$OD_PATH" 2>/dev/null | grep -qi 'SCLK'; then
    sclk_line=$(grep -i 'SCLK' "$OD_PATH" 2>/dev/null | grep -i 'Mhz' | tail -n1)
    pass "OD_RANGE SCLK present (plugin GPU-range parser will work)"
    [ -n "$sclk_line" ] && info "SCLK range: $(printf '%s' "$sclk_line" | sed 's/^[[:space:]]*//')"
  else
    warn "pp_od_clk_voltage found but no 'OD_RANGE: SCLK' entry; manual GPU clocks may be limited"
  fi
else
  warn "pp_od_clk_voltage not found; GPU clock range controls unavailable"
fi

if [ -n "$LEVEL_PATH" ]; then
  pass "Found power_dpm_force_performance_level ($LEVEL_PATH)"
else
  warn "power_dpm_force_performance_level not found; GPU performance-level modes unavailable"
fi

# ----------------------------------------------------------------------------
# 6. CPU management sysfs (boost / SMT / scaling driver)
# ----------------------------------------------------------------------------

header "6. CPU management sysfs"

SCALING_DRIVER=$(read_file /sys/devices/system/cpu/cpufreq/policy0/scaling_driver)
info "scaling driver : ${SCALING_DRIVER:-<unknown>}"
case "$SCALING_DRIVER" in
  amd-pstate-epp) pass "scaling driver is amd-pstate-epp (EPP controls available)" ;;
  amd-pstate)     warn "scaling driver is amd-pstate (no EPP; passive mode)" ;;
  acpi-cpufreq)   warn "scaling driver is acpi-cpufreq (legacy; limited controls)" ;;
  "")             warn "could not read scaling driver" ;;
  *)              warn "unexpected scaling driver '$SCALING_DRIVER'" ;;
esac

BOOST_PATH=$(ls /sys/devices/system/cpu/cpufreq/policy*/boost 2>/dev/null | head -n1)
if [ -n "$BOOST_PATH" ] || [ -e /sys/devices/system/cpu/cpufreq/boost ]; then
  pass "CPU boost control available"
else
  warn "No CPU boost sysfs found (boost controls will be hidden)"
fi

SMT_STATE=$(read_file /sys/devices/system/cpu/smt/control)
if [ "$SMT_STATE" = "on" ] || [ "$SMT_STATE" = "off" ]; then
  pass "SMT control available (state: $SMT_STATE)"
else
  warn "SMT control not toggleable (state: ${SMT_STATE:-<unknown>})"
fi

# ----------------------------------------------------------------------------
# 7. Optional write test
# ----------------------------------------------------------------------------

if [ "$WRITE_TEST" -eq 1 ]; then
  header "7. Write test (--write-test)"

  if [ "$(id -u)" -ne 0 ]; then
    fail "--write-test requires root; re-run with sudo"
  elif [ -z "$WMI_DIR" ] || [ -z "$GZ_DIR" ]; then
    fail "Cannot run write test: WMI attributes or gamezone profile not found"
  else
    SPL_CUR="$WMI_DIR/ppt_pl1_spl/current_value"
    SPL_MIN=$(read_file "$WMI_DIR/ppt_pl1_spl/min_value")
    orig_spl=$(read_file "$SPL_CUR")
    orig_profile=$(read_file "${GZ_DIR}profile")
    target="${SPL_MIN:-}"

    if [ -z "$target" ]; then
      fail "Could not read ppt_pl1_spl/min_value; aborting write test"
    else
      info "original profile=$orig_profile ppt_pl1_spl=$orig_spl ; test target=$target"

      # writes only take effect in 'custom' mode
      if echo "custom" > "${GZ_DIR}profile" 2>/dev/null; then
        info "set platform profile -> custom"
      else
        warn "could not set platform profile to custom"
      fi

      sleep 0.3
      if echo "$target" > "$SPL_CUR" 2>/dev/null; then
        sleep 0.3
        readback=$(read_file "$SPL_CUR")
        if [ "$readback" = "$target" ]; then
          pass "WMI TDP write took effect (wrote $target, read back $readback)"
        else
          warn "Wrote $target but read back '$readback' (firmware may not apply the value)"
        fi
      else
        fail "Failed to write ppt_pl1_spl (permission or firmware issue)"
      fi

      # restore original state
      if [ -n "$orig_spl" ]; then
        echo "$orig_spl" > "$SPL_CUR" 2>/dev/null && info "restored ppt_pl1_spl -> $orig_spl"
      fi
      if [ -n "$orig_profile" ]; then
        echo "$orig_profile" > "${GZ_DIR}profile" 2>/dev/null && info "restored platform profile -> $orig_profile"
      fi
    fi
  fi
fi

# ----------------------------------------------------------------------------
# summary
# ----------------------------------------------------------------------------

header "Summary"
printf "  ${C_GREEN}%d passed${C_RESET}, ${C_YELLOW}%d warnings${C_RESET}, ${C_RED}%d failed${C_RESET}\n" \
  "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
  printf "\n${C_RED}Not compatible with the WMI TDP path as-is.${C_RESET} The plugin will fall back to ryzenadj (needs Secure Boot off / iomem=relaxed).\n"
  exit 1
elif [ "$WARN_COUNT" -gt 0 ]; then
  printf "\n${C_YELLOW}Likely compatible, but review the warnings above.${C_RESET}\n"
  exit 0
else
  printf "\n${C_GREEN}All checks passed - the Legion Go 2 WMI TDP path should work.${C_RESET}\n"
  exit 0
fi
