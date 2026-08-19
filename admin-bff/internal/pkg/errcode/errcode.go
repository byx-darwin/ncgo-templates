package errcode

import frameworkerror "github.com/byx-darwin/go-tools/go-framework/error"

// Re-export predefined framework error codes from go-framework/error.
var (
    CodeSystem         = frameworkerror.CodeSystem
    CodeParamInvalid   = frameworkerror.CodeParamInvalid
    CodeAuthFailed     = frameworkerror.CodeAuthFailed
    CodeConfigInvalid  = frameworkerror.CodeConfigInvalid
    CodeRPCTimeout     = frameworkerror.CodeRPCTimeout
    CodeRPCUnavailable = frameworkerror.CodeRPCUnavailable
)