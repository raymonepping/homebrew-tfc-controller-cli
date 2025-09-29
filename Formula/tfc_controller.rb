# Formula/tfc_controller.rb
class TfcController < Formula
  desc "Bash-powered Terraform Cloud controller CLI (export/show org data)"
  homepage "https://github.com/raymonepping/tfc_controller"
  url "https://github.com/raymonepping/homebrew-tfc-controller-cli/archive/refs/tags/v1.0.4.tar.gz"
  sha256 "d5558cd419c8d46bdc958064cb97f963d1ea793866414c025906ec15033512ed"
  license "MIT"
  version "1.0.4"

  depends_on "bash"
  depends_on "jq"

  def install
    # Ship everything under libexec to keep the path clean
    libexec.install Dir["*"]

    # Make sure any scripts in libexec/bin are executable
    Dir["#{libexec}/bin/*"].each { |f| chmod 0755, f }

    # Wrapper so users can run `tfc_controller`
    (bin/"tfc_controller").write <<~SH
      #!/usr/bin/env bash
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
    assert_match "tfc_controller", shell_output("#{bin}/tfc_controller -V")
  end
end
