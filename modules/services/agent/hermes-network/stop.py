import sys

sys.path.insert(0, sys.argv[1])
from systemd_manager import SystemdManager

unit = f"hermes-netns@{sys.argv[2]}.service"
SystemdManager().stop_unit(unit)
print(f"NETWORK_FAILURE_REAPER_QUEUED unit={unit}", flush=True)
