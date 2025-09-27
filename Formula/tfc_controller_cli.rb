class TfcController < Formula
  desc "Bash-powered Terraform Cloud controller CLI"
  homepage "https://github.com/raymonepping/tfc_controller"
  url "https://github.com/raymonepping/tfc_controller/archive/refs/tags/1.0.0.tar.gz"
  sha256 "d4cf167082d40991d4bc703248690b83bc0410215e705bec9e6f65cf833c3d62"
  license "MIT"
  version "1.0.0"

  depends_on "bash"
  depends_on "jq"

  def install
    # Install all repo contents under libexec
    libexec.install Dir["*"]

    # Ensure the main script is executable
    chmod 0755, libexec/"bin/tfc_controller.sh"

    # Wrapper so users can run `tfc_controller` from PATH
    (bin/"tfc_controller").write <<~SH
      #!/usr/bin/env bash
      exec "#{libexec}/bin/tfc_controller.sh" "$@"
    SH
    (bin/"tfc_controller").chmod 0755
  end

  def caveats
    <<~EOS
      ⚙️  Configure environment:
        Create a .env file near your project or export:
          export TFE_TOKEN=...   # required
          export TFE_HOST=app.terraform.io

      💡 Optional: Install gum for pretty UI spinners/tables:
          brew install charmbracelet/tap/gum
    EOS
  end

  test do
    # Should print version or help text
    assert_match "tfc_controller", shell_output("#{bin}/tfc_controller -V")
  end
end
