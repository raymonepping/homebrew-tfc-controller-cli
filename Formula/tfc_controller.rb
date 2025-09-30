# Formula/tfc_controller.rb
class TfcController < Formula
  desc "Bash-powered Terraform Cloud controller CLI (export/show org data)"
  homepage "https://github.com/raymonepping/tfc_controller"
  url "https://github.com/raymonepping/tfc_controller/archive/refs/tags/v2.0.5.tar.gz"
  sha256 "277f869dadde55fa4fc2041b6940845463b33c9b6b3a875ccae7b62c9238c790"
  license "MIT"
  version "2.0.5"

  depends_on "bash"
  depends_on "jq"

  def install
    libexec.install Dir["*"]
    Dir["#{libexec}/bin/*"].each { |f| chmod 0755, f }

    (bin/"tfc_controller").write <<~SH
      #!/usr/bin/env bash
      export TFC_ROOT="#{libexec}"
      export TFC_VERSION="#{version}"     # <-- pass Homebrew package version
      exec "#{Formula["bash"].opt_bin}/bash" "#{libexec}/bin/tfc_controller.sh" "$@"
    SH
    (bin/"tfc_controller").chmod 0755
  end

  def caveats
    <<~EOS
      🚀 Quickstart:
        tfc_controller -h

      🔧 Env:
        export TFE_HOST=app.terraform.io
        export TFE_TOKEN=<your token>

      Optional UI niceties:
        brew install charmbracelet/tap/gum
    EOS
  end

  test do
    assert_match "tfc_controller v", shell_output("#{bin}/tfc_controller -V")
  end
end
