# Homebrew formula, tapped straight from this repository:
#   brew tap Chandram-Dutta/sochi https://github.com/Chandram-Dutta/sochi
#   brew install sochi            # latest release (universal binary)
#   brew install --HEAD sochi     # build from main
# The release URL, version and checksum are updated by the release workflow when a GitHub release is published.
class Sochi < Formula
  desc "Build, run and edit Xcode projects without opening Xcode"
  homepage "https://github.com/Chandram-Dutta/sochi"
  url "https://github.com/Chandram-Dutta/sochi/releases/download/v0.0.1/sochi-macos-universal.tar.gz"
  version "0.0.1"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "Apache-2.0"
  head "https://github.com/Chandram-Dutta/sochi.git", branch: "main"

  depends_on :macos
  depends_on xcode: "16.0"

  def install
    if build.head?
      system "swift", "build", "--disable-sandbox", "-c", "release"
      bin.install ".build/release/sochi"
    else
      bin.install "sochi"
    end
  end

  test do
    assert_match "Build and run", shell_output("#{bin}/sochi --help")
  end
end
