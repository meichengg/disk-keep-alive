cask "disk-keep-alive" do
  version "1.0.0"
  sha256 "586e62e8717299924e5fae04f1d9bfbbf95b5409a27b7329be9ead5a0e3a872f"

  url "https://github.com/meichengg/disk-keep-alive/releases/download/v#{version}/DiskKeepAlive-#{version}.dmg"
  name "Disk Keep Alive"
  desc "Prevent external HDDs from spinning down"
  homepage "https://github.com/meichengg/disk-keep-alive"

  depends_on macos: ">= :monterey"

  livecheck do
    url :url
    strategy :github_releases
  end

  app "Disk Keep Alive.app"

  zap trash: "~/Library/Preferences/com.local.diskKeepalive.plist"
end
