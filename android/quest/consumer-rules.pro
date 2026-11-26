# Quest VR player consumer ProGuard rules (1.6.29).
#
# VrPlayerPlugin is instantiated reflectively from PlezyActivity
# (Class.forName("com.plentv.quest.VrPlayerPlugin")), so R8 must not strip
# it or its no-arg constructor. VrPlayerActivity is referenced from the
# module manifest (kept), and the JNI methods are `native` (R8 keeps
# native methods by default).
-keep class com.plentv.quest.VrPlayerPlugin {
  public <init>();
}
