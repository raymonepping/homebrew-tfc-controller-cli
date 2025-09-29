# Formula/tfc_controller.rb
class TfcController < Formula
  desc "Bash-powered Terraform Cloud controller CLI (export/show org data)"
  homepage "https://github.com/raymonepping/tfc_controller"
  url "https://github.com/raymonepping/tfc_controller/archive/refs/tags/v2.0.1.tar.gz"
  sha256 "d9027909e445325a6cbaaf94663d25d2cd19eb80d7cc6e91a0f4a59ff5550fc8"
  license "MIT"
  version "2.0.1"

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
