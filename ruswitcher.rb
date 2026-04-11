cask "ruswitcher" do
  version "2.0.2"
  sha256 "a1daf9d8878961eb3b5a8a26e3e63606c57af8a8ef08bf2512e4f978a7fe7df5"

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
