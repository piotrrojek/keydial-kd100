# Homebrew formula for aerospace-kd100.
#
# This is the template kept in-repo. On each release, the workflow prints the new
# url + sha256 ("Print Homebrew SHA256" step); copy this file into
# piotrrojek/homebrew-tap as Formula/aerospace-kd100.rb with those values filled in.
#
# Install (once public + in the tap):
#   brew install piotrrojek/tap/aerospace-kd100
class AerospaceKd100 < Formula
  desc "Drive a Huion KD100 keypad + knob as an AeroSpace controller (no Huion driver)"
  homepage "https://github.com/piotrrojek/aerospace-kd100"
  url "https://github.com/piotrrojek/aerospace-kd100/releases/download/v0.1.0/aerospace-kd100-0.1.0-macos-universal.tar.gz"
  sha256 "174ee8364d3b87a3b0187aa321128d5b33d748a5ecc478785a4198633e472ef8"
  version "0.1.0"
  license "MIT"

  depends_on :macos

  def install
    # The tarball's single top-level dir (kd100.app) is stripped by Homebrew on
    # extraction, so the staged files are the bundle's innards (Contents/…).
    # Reconstruct kd100.app from them.
    (prefix/"kd100.app").install Dir["*"]
    bin.install_symlink prefix/"kd100.app/Contents/MacOS/kd100"
  end

  service do
    run [opt_bin/"kd100", "run"]
    keep_alive true
    log_path var/"log/kd100.log"
    error_log_path var/"log/kd100.log"
  end

  def caveats
    <<~EOS
      kd100 reads the keypad's raw HID device, which needs two one-time manual steps
      (Homebrew cannot grant them for you):

        1. Input Monitoring — start the service, then enable "kd100" in
           System Settings > Privacy & Security > Input Monitoring, then:
             brew services restart aerospace-kd100

        2. If you run Karabiner-Elements, it grabs the keypad by default. Set the
           KD100 (vendor 0x256c / product 0x6d) to "ignore" in Karabiner's Devices
           tab so kd100 can seize it (otherwise: kIOReturnExclusiveAccess).

      Remap by editing ~/.config/kd100/mapping.json (created on first run), then:
        brew services restart aerospace-kd100

      Requires AeroSpace: brew install --cask nikitabobko/tap/aerospace
    EOS
  end

  test do
    assert_match "usage", shell_output("#{bin}/kd100 --bogus 2>&1", 2)
  end
end
