cask "disk-keep-alive" do
  version "1.0.0"
  sha256 "REPLACE_WITH_SHA256_OF_DMG"

  url "https://github.com/meichengg/disk-keep-alive/releases/download/v#{version}/DiskKeepAlive-#{version}.dmg"
  name "Disk Keep Alive"
  desc "Prevent external HDDs from spinning down"
  homepage "https://github.com/meichengg/disk-keep-alive"

  depends_on macos: ">= :monterey"

  app "Disk Keep Alive.app"

  zap trash: "~/Library/Preferences/com.local.diskKeepalive.plist"
end
