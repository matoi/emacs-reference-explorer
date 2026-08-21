#include <emacs-module.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#import <AppKit/AppKit.h>
#import <CoreServices/CoreServices.h>

int plugin_is_GPL_compatible;

static BOOL
reference_explorer_hide_definition(void)
{
  Class definitionModule = NSClassFromString(@"LULookupDefinitionModule");
  SEL hideDefinition = NSSelectorFromString(@"hideDefinition");
  if (definitionModule == Nil ||
      ![definitionModule respondsToSelector:hideDefinition])
    return NO;

  typedef void (*HideDefinitionFunction)(id, SEL);
  HideDefinitionFunction hide =
    (HideDefinitionFunction)[definitionModule methodForSelector:hideDefinition];
  if (hide == NULL)
    return NO;
  hide(definitionModule, hideDefinition);
  return YES;
}

static NSView *
reference_explorer_view_at_screen_point(NSPoint screenPoint)
{
  NSApplication *application = NSApp ?: NSApplication.sharedApplication;
  NSWindow *window = nil;
  for (NSWindow *candidate in application.orderedWindows) {
    if (candidate.isVisible && NSPointInRect(screenPoint, candidate.frame)) {
      window = candidate;
      break;
    }
  }
  window = window ?: application.keyWindow ?: application.mainWindow;
  return window.contentView;
}

static NSPoint
reference_explorer_screen_point(ptrdiff_t emacsX, ptrdiff_t emacsY)
{
  NSScreen *mainScreen = NSScreen.mainScreen;
  if (mainScreen == nil)
    return NSMakePoint(NAN, NAN);

  // Emacs screen pixels use a top-left origin.  AppKit's global screen
  // coordinates use a bottom-left origin at the primary display.
  return NSMakePoint(emacsX, NSMaxY(mainScreen.frame) - emacsY);
}

static BOOL
reference_explorer_show_definition(NSString *text, NSPoint screenPoint,
                                   NSString *fontName, NSString *fontWeight,
                                   CGFloat fontSize)
{
  NSView *view = reference_explorer_view_at_screen_point(screenPoint);
  if (view == nil)
    return NO;

  NSWindow *window = view.window;
  NSPoint windowPoint = [window convertPointFromScreen:screenPoint];
  NSPoint viewPoint = [view convertPoint:windowPoint fromView:nil];
  NSFont *font = nil;
  if (fontName.length > 0 && fontSize > 0) {
    CGFloat weight = NSFontWeightRegular;
    if ([fontWeight isEqualToString:@"ultralight"])
      weight = NSFontWeightUltraLight;
    else if ([fontWeight isEqualToString:@"thin"])
      weight = NSFontWeightThin;
    else if ([fontWeight isEqualToString:@"light"])
      weight = NSFontWeightLight;
    else if ([fontWeight isEqualToString:@"medium"])
      weight = NSFontWeightMedium;
    else if ([fontWeight isEqualToString:@"semibold"])
      weight = NSFontWeightSemibold;
    else if ([fontWeight isEqualToString:@"bold"])
      weight = NSFontWeightBold;
    else if ([fontWeight isEqualToString:@"heavy"])
      weight = NSFontWeightHeavy;
    else if ([fontWeight isEqualToString:@"black"])
      weight = NSFontWeightBlack;
    NSFontDescriptor *descriptor =
      [NSFontDescriptor fontDescriptorWithFontAttributes:@{
        NSFontFamilyAttribute : fontName,
        NSFontTraitsAttribute : @{ NSFontWeightTrait : @(weight) }
      }];
    font = [NSFont fontWithDescriptor:descriptor size:fontSize];
  }
  NSMutableDictionary<NSAttributedStringKey, id> *attributes =
    [NSMutableDictionary dictionary];
  if (font != nil)
    attributes[NSFontAttributeName] = font;
  attributes[NSForegroundColorAttributeName] = NSColor.blackColor;
  NSAttributedString *attributed =
    [[NSAttributedString alloc] initWithString:text attributes:attributes];
  [view showDefinitionForAttributedString:attributed atPoint:viewPoint];
  return YES;
}

static char *
reference_explorer_copy_utf8(emacs_env *env, emacs_value value,
                             ptrdiff_t *size)
{
  *size = 0;
  env->copy_string_contents(env, value, NULL, size);
  char *utf8 = malloc((size_t)*size);
  if (utf8 != NULL)
    env->copy_string_contents(env, value, utf8, size);
  return utf8;
}

static NSString *
reference_explorer_term_at_utf8_offset(const char *utf8, ptrdiff_t size,
                                        ptrdiff_t byteOffset,
                                        NSRange *selectedRange)
{
  if (byteOffset < 0 || byteOffset >= size)
    return nil;

  NSString *text = [[NSString alloc] initWithUTF8String:utf8];
  NSString *prefix =
    [[NSString alloc] initWithBytes:utf8
                             length:(NSUInteger)byteOffset
                           encoding:NSUTF8StringEncoding];
  if (text == nil || prefix == nil || text.length == 0)
    return nil;

  // Emacs point is an insertion position immediately before the glyph under
  // the cursor.  Dictionary Services also accepts a boundary offset, but at
  // the beginning of a word it may resolve that boundary to the word on its
  // left.  Accept a result only when it contains the glyph under point; when
  // it does not, retry at the following composed-character boundary.
  CFIndex targetOffset = (CFIndex)prefix.length;
  if (targetOffset >= (CFIndex)text.length)
    targetOffset = (CFIndex)text.length - 1;
  CFRange termRange =
    DCSGetTermRangeInString(NULL, (__bridge CFStringRef)text, targetOffset);
  BOOL containsTarget =
    termRange.location != kCFNotFound && termRange.length > 0 &&
    targetOffset >= termRange.location &&
    targetOffset < termRange.location + termRange.length;
  if (!containsTarget) {
    NSRange characterRange =
      [text rangeOfComposedCharacterSequenceAtIndex:(NSUInteger)targetOffset];
    CFIndex followingBoundary = (CFIndex)NSMaxRange(characterRange);
    if (followingBoundary < (CFIndex)text.length) {
      termRange = DCSGetTermRangeInString(
        NULL, (__bridge CFStringRef)text, followingBoundary);
      containsTarget =
        termRange.location != kCFNotFound && termRange.length > 0 &&
        targetOffset >= termRange.location &&
        targetOffset < termRange.location + termRange.length;
    }
  }
  if (!containsTarget ||
      termRange.location + termRange.length > (CFIndex)text.length)
    return nil;

  NSRange range = NSMakeRange((NSUInteger)termRange.location,
                              (NSUInteger)termRange.length);
  if (selectedRange != NULL)
    *selectedRange = range;
  return [text substringWithRange:range];
}

static emacs_value
reference_explorer_macos_show_definition(emacs_env *env, ptrdiff_t nargs,
                                         emacs_value *args, void *data)
{
  (void)nargs;
  (void)data;

  ptrdiff_t size;
  char *utf8 = reference_explorer_copy_utf8(env, args[0], &size);
  if (utf8 == NULL)
    return env->intern(env, "nil");
  ptrdiff_t emacsX = env->extract_integer(env, args[1]);
  ptrdiff_t emacsY = env->extract_integer(env, args[2]);
  BOOL shown = NO;
  @autoreleasepool {
    NSString *text = [[NSString alloc] initWithUTF8String:utf8];
    if (text != nil && text.length > 0) {
      NSPoint screenPoint = reference_explorer_screen_point(emacsX, emacsY);
      if (!isnan(screenPoint.x))
        shown = reference_explorer_show_definition(
          text, screenPoint, nil, nil, 0);
    }
  }
  free(utf8);
  return env->intern(env, shown ? "t" : "nil");
}

static emacs_value
reference_explorer_macos_show_definition_with_font(
  emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
  (void)nargs;
  (void)data;

  ptrdiff_t textSize;
  char *textUtf8 = reference_explorer_copy_utf8(env, args[0], &textSize);
  ptrdiff_t fontNameSize;
  char *fontUtf8 =
    reference_explorer_copy_utf8(env, args[3], &fontNameSize);
  ptrdiff_t fontWeightSize;
  char *weightUtf8 =
    reference_explorer_copy_utf8(env, args[4], &fontWeightSize);
  if (textUtf8 == NULL || fontUtf8 == NULL || weightUtf8 == NULL) {
    free(textUtf8);
    free(fontUtf8);
    free(weightUtf8);
    return env->intern(env, "nil");
  }
  ptrdiff_t emacsX = env->extract_integer(env, args[1]);
  ptrdiff_t emacsY = env->extract_integer(env, args[2]);
  double fontSize = env->extract_float(env, args[5]);
  BOOL shown = NO;
  @autoreleasepool {
    NSString *text = [[NSString alloc] initWithUTF8String:textUtf8];
    NSString *fontName = [[NSString alloc] initWithUTF8String:fontUtf8];
    NSString *fontWeight = [[NSString alloc] initWithUTF8String:weightUtf8];
    if (text != nil && text.length > 0 && fontName != nil &&
        fontWeight != nil) {
      NSPoint screenPoint = reference_explorer_screen_point(emacsX, emacsY);
      if (!isnan(screenPoint.x))
        shown = reference_explorer_show_definition(
          text, screenPoint, fontName, fontWeight, (CGFloat)fontSize);
    }
  }
  free(textUtf8);
  free(fontUtf8);
  free(weightUtf8);
  return env->intern(env, shown ? "t" : "nil");
}

static emacs_value
reference_explorer_macos_show_definition_at_offset(
  emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
  (void)nargs;
  (void)data;

  ptrdiff_t size;
  char *utf8 = reference_explorer_copy_utf8(env, args[0], &size);
  if (utf8 == NULL)
    return env->intern(env, "nil");
  ptrdiff_t byteOffset = env->extract_integer(env, args[1]);
  ptrdiff_t emacsX = env->extract_integer(env, args[2]);
  ptrdiff_t emacsY = env->extract_integer(env, args[3]);
  BOOL shown = NO;
  @autoreleasepool {
    NSString *term =
      reference_explorer_term_at_utf8_offset(utf8, size, byteOffset, NULL);
    if (term != nil) {
      NSPoint screenPoint = reference_explorer_screen_point(emacsX, emacsY);
      if (!isnan(screenPoint.x))
        shown = reference_explorer_show_definition(
          term, screenPoint, nil, nil, 0);
    }
  }
  free(utf8);
  return env->intern(env, shown ? "t" : "nil");
}

static emacs_value
reference_explorer_macos_term_at_offset(emacs_env *env, ptrdiff_t nargs,
                                         emacs_value *args, void *data)
{
  (void)nargs;
  (void)data;

  ptrdiff_t size;
  char *utf8 = reference_explorer_copy_utf8(env, args[0], &size);
  if (utf8 == NULL)
    return env->intern(env, "nil");
  ptrdiff_t byteOffset = env->extract_integer(env, args[1]);
  char *termUtf8 = NULL;
  ptrdiff_t termSize = 0;
  @autoreleasepool {
    NSString *term =
      reference_explorer_term_at_utf8_offset(utf8, size, byteOffset, NULL);
    if (term != nil) {
      termSize = (ptrdiff_t)[term lengthOfBytesUsingEncoding:
                                    NSUTF8StringEncoding];
      termUtf8 = malloc((size_t)termSize + 1);
      if (termUtf8 != NULL)
        memcpy(termUtf8, term.UTF8String, (size_t)termSize + 1);
    }
  }
  free(utf8);
  if (termUtf8 == NULL)
    return env->intern(env, "nil");
  emacs_value result = env->make_string(env, termUtf8, termSize);
  free(termUtf8);
  return result;
}

static emacs_value
reference_explorer_macos_selection_at_offset(emacs_env *env, ptrdiff_t nargs,
                                              emacs_value *args, void *data)
{
  (void)nargs;
  (void)data;

  ptrdiff_t size;
  char *utf8 = reference_explorer_copy_utf8(env, args[0], &size);
  if (utf8 == NULL)
    return env->intern(env, "nil");
  ptrdiff_t byteOffset = env->extract_integer(env, args[1]);
  char *termUtf8 = NULL;
  ptrdiff_t termSize = 0;
  NSUInteger startByte = 0;
  NSUInteger endByte = 0;
  @autoreleasepool {
    NSString *text = [[NSString alloc] initWithUTF8String:utf8];
    NSRange range;
    NSString *term = reference_explorer_term_at_utf8_offset(
      utf8, size, byteOffset, &range);
    if (text != nil && term != nil) {
      NSString *prefix = [text substringToIndex:range.location];
      NSString *selected = [text substringWithRange:range];
      startByte =
        [prefix lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
      endByte = startByte +
        [selected lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
      termSize = (ptrdiff_t)[term lengthOfBytesUsingEncoding:
                                    NSUTF8StringEncoding];
      termUtf8 = malloc((size_t)termSize + 1);
      if (termUtf8 != NULL)
        memcpy(termUtf8, term.UTF8String, (size_t)termSize + 1);
    }
  }
  free(utf8);
  if (termUtf8 == NULL)
    return env->intern(env, "nil");
  emacs_value values[] = {
    env->make_string(env, termUtf8, termSize),
    env->make_integer(env, (ptrdiff_t)startByte),
    env->make_integer(env, (ptrdiff_t)endByte)
  };
  free(termUtf8);
  return env->funcall(env, env->intern(env, "list"), 3, values);
}

static emacs_value
reference_explorer_macos_hide_definition(emacs_env *env, ptrdiff_t nargs,
                                          emacs_value *args, void *data)
{
  (void)nargs;
  (void)args;
  (void)data;

  BOOL hidden;
  @autoreleasepool {
    hidden = reference_explorer_hide_definition();
  }
  return env->intern(env, hidden ? "t" : "nil");
}

int
emacs_module_init(struct emacs_runtime *runtime)
{
  emacs_env *env = runtime->get_environment(runtime);
  emacs_value function = env->make_function(
    env, 3, 3, reference_explorer_macos_show_definition,
    "Show the macOS Dictionary definition for TEXT at SCREEN-X, SCREEN-Y.",
    NULL);
  emacs_value symbol =
    env->intern(env, "reference-explorer-source-macos-show-definition");
  emacs_value defalias = env->intern(env, "defalias");
  emacs_value aliasArgs[] = { symbol, function };
  env->funcall(env, defalias, 2, aliasArgs);

  emacs_value fontFunction = env->make_function(
    env, 6, 6, reference_explorer_macos_show_definition_with_font,
    "Show TEXT using its source baseline, font, weight, and size.",
    NULL);
  emacs_value fontSymbol =
    env->intern(env, "reference-explorer-source-macos-show-definition-with-font");
  emacs_value fontAliasArgs[] = { fontSymbol, fontFunction };
  env->funcall(env, defalias, 2, fontAliasArgs);

  emacs_value automaticFunction = env->make_function(
    env, 4, 4, reference_explorer_macos_show_definition_at_offset,
    "Show the macOS Dictionary term selected around UTF8-BYTE-OFFSET in TEXT.",
    NULL);
  emacs_value automaticSymbol =
    env->intern(env, "reference-explorer-source-macos-show-definition-at-offset");
  emacs_value automaticAliasArgs[] = { automaticSymbol, automaticFunction };
  env->funcall(env, defalias, 2, automaticAliasArgs);

  emacs_value termFunction = env->make_function(
    env, 2, 2, reference_explorer_macos_term_at_offset,
    "Return the macOS Dictionary term around UTF8-BYTE-OFFSET in TEXT.",
    NULL);
  emacs_value termSymbol =
    env->intern(env, "reference-explorer-source-macos-term-at-offset");
  emacs_value termAliasArgs[] = { termSymbol, termFunction };
  env->funcall(env, defalias, 2, termAliasArgs);

  emacs_value selectionFunction = env->make_function(
    env, 2, 2, reference_explorer_macos_selection_at_offset,
    "Return (TERM START-BYTE END-BYTE) selected around UTF8-BYTE-OFFSET.",
    NULL);
  emacs_value selectionSymbol =
    env->intern(env, "reference-explorer-source-macos-selection-at-offset");
  emacs_value selectionAliasArgs[] = { selectionSymbol, selectionFunction };
  env->funcall(env, defalias, 2, selectionAliasArgs);

  emacs_value hideFunction = env->make_function(
    env, 0, 0, reference_explorer_macos_hide_definition,
    "Hide the system Dictionary definition displayed by this module.", NULL);
  emacs_value hideSymbol =
    env->intern(env, "reference-explorer-source-macos-hide-definition");
  emacs_value hideAliasArgs[] = { hideSymbol, hideFunction };
  env->funcall(env, defalias, 2, hideAliasArgs);

  emacs_value provide = env->intern(env, "provide");
  emacs_value feature =
    env->intern(env, "reference-explorer-source-macos-module");
  env->funcall(env, provide, 1, &feature);
  return 0;
}
