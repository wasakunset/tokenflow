# Homebrew cask template — goes in a tap repo (github.com/<user>/homebrew-tap)
# at Casks/<app-name>.rb once the first GitHub release exists.
# Update: version, sha256 (shasum -a 256 <zip>), URLs, and names if renamed.
cask "tokenflow" do
  version "1.0"
  sha256 "REPLACE_WITH_SHA256_OF_RELEASE_ZIP"

  url "https://github.com/wasakunset/tokenflow/releases/download/v#{version}/TokenFlow.zip"
  name "TokenFlow"
  desc "Claude and Codex rate limits in the menu bar"
  homepage "https://github.com/wasakunset/tokenflow"

  depends_on macos: ">= :ventura"

  app "TokenFlow.app"

  # Unsigned build: clear quarantine so Gatekeeper doesn't block first launch.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine",
                          "#{appdir}/TokenFlow.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Preferences/com.wasakunset.tokenflow.plist",
  ]
end
