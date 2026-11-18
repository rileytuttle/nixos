# Bootstrapping fw12-rack-headless

One-time steps to get from "bare NixOS install, no desktop, physically
racked" to "running `hosts/fw12-rack-headless.nix` from this flake,
reachable headless." Delete this file once the host is up and these steps
are no longer needed.

Starting point assumed: NixOS is installed on the board with no desktop
environment (the ISO's own minimal config), it boots, and you have a
console or local login — but it is not yet running anything from this repo.

## 1. Push this repo's pending changes

`flake.nix`, `hosts/fw12-rack-headless.nix` and
`hosts/fw12-rack-headless-hardware-configuration.nix` are currently staged
on the dev machine but not committed/pushed. The new host won't see any of
this until it's on `origin`:

```bash
git commit -m "fw12-rack-headless: add host"
git push
```

(The hardware-config file is a **placeholder** — fabricated UUIDs, modeled
on fw12's pre-upgrade scan. Step 4 below replaces it with the real one.)

## 2. Set the hostname

`scripts/refresh-hardware-config.nix` (step 4) refuses to write a host file
that doesn't match `uname -n`, unless forced. Make the live hostname match
the one in `hosts/fw12-rack-headless.nix` now:

```bash
sudo hostnamectl set-hostname fw12-rack-headless
```

## 3. Get this repo onto the machine

`origin` is SSH (`git@github.com:rileytuttle/nixos.git`), so this machine
needs its own key GitHub recognizes. Generate one and register it rather
than copying a private key over from another box:

```bash
nix-shell -p openssh git --run bash
mkdir -p ~/.ssh
ssh-keygen -t ed25519 -C "rileytuttle@fw12-rack-headless" -f ~/.ssh/id_ed25519
cat ~/.ssh/id_ed25519.pub
```

Add that public key to GitHub — either paste it in at
<https://github.com/settings/ssh/new> (title it something like
`fw12-rack-headless`), or, if `gh` is authenticated somewhere you can reach:

```bash
gh ssh-key add ~/.ssh/id_ed25519.pub --title fw12-rack-headless
```

Confirm GitHub accepts it, then clone:

```bash
ssh -T git@github.com   # expect "Hi rileytuttle! You've successfully authenticated"
git clone git@github.com:rileytuttle/nixos.git ~/nixos
cd ~/nixos
```

(Still inside the `nix-shell` from above, or re-enter it with
`nix-shell -p openssh git --run bash` — minimal installs may not have
either on `PATH` by default.)

Flakes aren't enabled by default on a fresh install, so pass the feature
flags explicitly for every command below until the first `switch` lands
(it's `modules/common.nix` that makes them permanent via
`nix.settings.experimental-features`):

```bash
export NIX_CONFIG="experimental-features = nix-command flakes"
```

## 4. Replace the placeholder hardware config

```bash
nix run .#refresh-hardware-config
```

This overwrites `hosts/fw12-rack-headless-hardware-configuration.nix` with
a real `nixos-generate-config` scan (real filesystem UUIDs, whatever
disk/NIC modules this chassis actually needs) and `git add`s it. **Read the
diff it prints** before moving on — it's comparing the placeholder's fake
UUIDs against the real scan, so the whole `fileSystems` block will change;
make sure nothing else looks wrong (unexpected kernel modules, a missing
swap device, etc).

## 5. First build and switch

```bash
nix flake check   # builds every host, including fw12-rack-headless
sudo nixos-rebuild switch --flake .#fw12-rack-headless
```

If this is the very first `nixos-rebuild` on the box and flakes still
aren't picked up, prefix with the same experimental-features flag:

```bash
sudo nixos-rebuild switch --flake .#fw12-rack-headless --extra-experimental-features 'nix-command flakes'
```

This also activates the home-manager profile for `rileytuttle`
(`home/default.nix`, the same one fw12/elitedesk use — nothing has been
stripped out for headless yet, per the comment in `flake.nix`, so expect it
to build some GUI packages it will never run).

Right after it finishes, confirm `sshd` actually came up under the new
config, while you still have the console in front of you:

```bash
systemctl status sshd
ss -tlnp | grep :22
```

`services.openssh.openFirewall` defaults to `true`, so port 22 should be
open on every interface already — no extra firewall rule needed, despite
the commented-out one in `modules/ssh.nix`.

## 6. Set a login password

`modules/common.nix` creates `rileytuttle` as a normal user but sets no
`hashedPassword` (mutable users, intentionally no password hash in a public
repo). Set one now, before you lose local console access:

```bash
sudo passwd rileytuttle
```

## 7. Bring up Tailscale

```bash
sudo tailscale up
```

Follow the printed auth URL from another device. Once it's in your
tailnet, `networking.firewall.trustedInterfaces = [ "tailscale0" ]`
(`modules/tailscale.nix`) means anything over that interface skips the
firewall.

## 8. Confirm headless SSH access — before you walk away from the console

`modules/ssh.nix` has `openssh` enabled with password auth on and root
login off. Don't disconnect the local console until a remote login
actually succeeds — this is a headless rack box, so the console may be
the only way back in if something's wrong.

From another machine, first on the plain LAN (works as soon as step 5's
`switch` lands, independent of Tailscale):

```bash
ssh rileytuttle@<lan-ip-or-mdns-name>
```

Then over the tailnet, now that step 7 has it joined:

```bash
ssh rileytuttle@fw12-rack-headless   # Tailscale MagicDNS name
# or: ssh rileytuttle@<tailscale-ip>
```

Both should prompt for the password set in step 6 and drop you into a
shell. If either hangs or is refused, stay on the console and check
`systemctl status sshd` / `journalctl -u sshd` before doing anything else.

Once both work, you no longer need the local console, and future rebuilds
can be driven remotely:

```bash
nixos-rebuild switch --flake .#fw12-rack-headless --target-host rileytuttle@fw12-rack-headless --use-remote-sudo
```

## Loose end to revisit later

`flake.nix` currently gives this host the full personal home-manager
profile (`home/default.nix`), GUI apps (`home/apps-personal.nix`) included,
rather than a trimmed-down headless one. It works — nothing in it depends
on an X server — but it's wasted build time and closure size on a rack
server. Worth splitting out a headless-only home profile once this host is
otherwise stable.
