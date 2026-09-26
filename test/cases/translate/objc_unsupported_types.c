typedef struct {
    signed int _exponent:8;
    unsigned int _length:4;
    unsigned short _mantissa[8];
} NSDecimal;

@interface NSObject
@end

@interface NSDecimalNumber : NSObject
- (NSDecimal)decimalValue;
- (void)setDecimal:(NSDecimal)value;
- (NSDecimal *)decimalPointer;
- (unsigned long)length;
@end

// translate
// args=-fobjc
// target=aarch64-macos
//
//     // Methods of class `NSDecimalNumber`
//     pub const decimalPointer = __objc_methods_NSDecimalNumber(@This()).decimalPointer;
//     pub const length = __objc_methods_NSDecimalNumber(@This()).length;
//
//         // `- (NSDecimal)decimalValue` was not translated: unsupported type
//         // `- (void)setDecimal:(NSDecimal)value` was not translated: unsupported type
//         /// `- (NSDecimal *)decimalPointer`
//         pub fn decimalPointer(self: *Self) ?*NSDecimal {
