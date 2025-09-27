class TfcController < Formula
  desc "Bash-powered Terraform Cloud controller CLI"
  homepage "https://github.com/raymonepping/tfc_controller"
  url "https://github.com/raymonepping/tfc_controller/archive/refs/tags/v1.0.1.tar.gz"
  sha256 "d5558cd419c8d46bdc958064cb97f963d1ea793866414c025906ec15033512ed"
  license "MIT"
  version "1.0.1"

  depends_on "bash"
  depends_on "jq"

  def install
    libexec.install Dir["*"]
    # ensure the main entry point is executable
    chmod 0755, libexec/"bin/tfc_controller.sh"

    (bin/"tfc_controller").write <<~SH
      #!/usr/bin/env bash
      exec "#{libexec}/bin/tfc_controller.sh" "$@"
    SH
    (bin/"tfc_controller").chmod 0755
  end

  def caveats
    <<~EOS
      ⚙️  Configure environment:
        export TFE_TOKEN=...   # required
        export TFE_HOST=app.terraform.io

      💡 Optional (prettier UI): brew install charmbracelet/tap/gum
    EOS
  end

  test do
    assert_match "tfc_controller v", shell_output("#{bin}/tfc_controller -V")
  end
end
