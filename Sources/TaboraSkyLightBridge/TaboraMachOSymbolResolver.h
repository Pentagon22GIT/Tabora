#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, TSLMachOSymbolResolutionStatus) {
    TSLMachOSymbolResolutionStatusResolved = 0,
    TSLMachOSymbolResolutionStatusImageMissing,
    TSLMachOSymbolResolutionStatusUnsupportedImage,
    TSLMachOSymbolResolutionStatusLinkeditMissing,
    TSLMachOSymbolResolutionStatusSymbolTableMissing,
    TSLMachOSymbolResolutionStatusMalformedImage,
    TSLMachOSymbolResolutionStatusSymbolMissing,
    TSLMachOSymbolResolutionStatusSymbolNotExecutable,
};

FOUNDATION_EXPORT void * _Nullable TSLResolveLocalMachOSymbol(
    const char * _Nonnull imagePath,
    const char * _Nonnull symbolName,
    TSLMachOSymbolResolutionStatus * _Nullable status
);

FOUNDATION_EXPORT NSString * _Nonnull
TSLMachOSymbolResolutionStatusDescription(
    TSLMachOSymbolResolutionStatus status
);
