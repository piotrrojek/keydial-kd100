# Homebrew formula for keydial-kd100.
#
# This is the template kept in-repo. On each release, the workflow prints the new
# url + sha256 ("Print Homebrew SHA256" step); copy this file into
# piotrrojek/homebrew-tap as Formula/keydial-kd100.rb with those values filled in.
#
# kd100 is now a menu-bar (tray) app, not a brew-services daemon — there is no
# `service` block. (A Homebrew Cask would arguably be a more natural fit for a GUI
# app; a formula that installs the bundle + opens it is kept here for continuity.)
#
# Install (once public + in the tap):
#   brew install piotrrojek/tap/keydial-kd100
class KeydialKd100 < Formula
  desc "Map a Huion KD100 keypad + knob to any shell command (no Huion driver)"
  homepage "https://github.com/piotrrojek/keydial-kd100"
  url "https://github.com/piotrrojek/keydial-kd100/releases/download/v0.5.0/keydial-kd100-0.5.0-macos-universal.tar.gz"
  sha256 "e29b279a560114aa63aff7cbdf74f022ca821411c1c1f7144ec691abd7a98842"
  version "0.5.0"
  license "MIT"

  depends_on :macos

  def install
    # The tarball's single top-level dir (kd100.app) is stripped by Homebrew on
    # extraction, so the staged files are the bundle's innards (Contents/…).
    # Reconstruct kd100.app from them.
    (prefix/"kd100.app").install Dir["*"]
    bin.install_symlink prefix/"kd100.app/Contents/MacOS/kd100"
  end

  def caveats
    <<~EOS
      kd100 is a menu-bar app. Launch it (it has no dock icon — look for the dial
      icon in the menu bar):
        open #{opt_prefix}/kd100.app

      Reading the keypad's raw HID device needs two one-time manual steps
      (Homebrew cannot grant them for you):

        1. Input Monitoring — after first launch, enable "kd100" in
           System Settings > Privacy & Security > Input Monitoring, then quit and
           relaunch the app from its menu.

        2. If you run Karabiner-Elements, it grabs the keypad by default. Set the
           KD100 (vendor 0x256c / product 0x6d) to "ignore" in Karabiner's Devices
           tab so kd100 can seize it (otherwise: kIOReturnExclusiveAccess).

      Map keys from the menu bar: kd100 > Settings… (writes ~/.config/kd100/mapping.json,
      applies live). Run at boot: kd100 > Open at Login.

      Ships with AeroSpace window-manager bindings as the default example; rebind to
      anything (open -a, osascript, scripts). For the defaults to do something:
        brew install --cask nikitabobko/tap/aerospace
    EOS
  end

  test do
    assert_match "usage", shell_output("#{bin}/kd100 --bogus 2>&1", 2)
  end
end
