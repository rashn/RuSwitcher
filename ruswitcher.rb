cask "ruswitcher" do
  version "2.0.1"
  sha256 "18012acbc2cc6c709e0e251471b2283ecf86cba7ae6449148e79853388d3418e"

  url "https://github.com/rashn/RuSwitcher/releases/download/v#{version}/RuSwitcher-#{version}.dmg"
  name "RuSwitcher"
  desc "Lightweight keyboard layout switcher, free alternative to PuntoSwitcher"
  homepage "https://github.com/rashn/RuSwitcher"

  depends_on macos: ">= :ventura"

  app "RuSwitcher.app"

  zap trash: [
    "~/Library/Logs/RuSwitcher",
    "~/Library/Preferences/com.ruswitcher.app.plist",
  ]
end
