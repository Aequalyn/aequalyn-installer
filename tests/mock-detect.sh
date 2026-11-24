#!/usr/bin/env bash
# mock of aequalyn-detect --json: plausible, harmless hardware with one fake
# disk. Never reads the real machine.
cat <<'EOF'
{
  "firmware": "UEFI",
  "cpu_vendor": "GenuineIntel",
  "gpu_vendors": "intel",
  "mem_gb": 16,
  "battery": "no",
  "disk_count": 1,
  "free_gb": 128,
  "boot_disk": "/dev/sr0",
  "win_efi": "",
  "mode": "fullwipe",
  "encrypt": false,
  "first_disk": "/dev/mock-disk",
  "profiles": ["minimal", "dev"],
  "browser": "chromium",
  "flatpak": false
}
EOF
