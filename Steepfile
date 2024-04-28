D = Steep::Diagnostic

target :lib do
  check "lib"

  library "json"
  library "time"

  signature "sig"
  signature "sig_gem"

  configure_code_diagnostics(D::Ruby.strict)
end
