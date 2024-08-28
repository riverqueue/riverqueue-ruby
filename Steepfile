D = Steep::Diagnostic

target :lib do
  check "lib"

  library "digest"
  library "json"
  library "time"

  signature "sig"

  configure_code_diagnostics(D::Ruby.strict)
end
