cask "ruswitcher" do
  version "2.0.2"
  sha256 "6d2630811b4613b433a463b86f3df32829a76d30a2ad11e120b288de162463c6"

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
