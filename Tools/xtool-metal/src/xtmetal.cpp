// xtmetal: Metal Shading Language -> AIR compiler core and metallib linker, built on clang/LLVM 15.
//
//   xtmetal compile <rewritten.ii> -o <out.air> --triple <air64-apple-...> --source <orig.metal>
//           [--fast-math] [--sdk-version 26.5] [--diag <file.dia>] [-- extra cc1 args]
//   xtmetal link -o <out.metallib> <in.air>...
//
// The input of `compile` is preprocessed MSL that the `metal` driver already rewrote into C++ for
// OpenCL (attributes as [[clang::annotate("air:...")]], address spaces as __global/__constant/__local).
// Entry points are found in the AST, the user functions are compiled with clang's spir64 target, and
// AIR entry functions with Apple's argument conventions and metadata are generated around them.

#include "clang/AST/ASTConsumer.h"
#include "clang/AST/ASTContext.h"
#include "clang/AST/Attr.h"
#include "clang/AST/DeclCXX.h"
#include "clang/AST/DeclTemplate.h"
#include "clang/AST/Mangle.h"
#include "clang/AST/RecordLayout.h"
#include "clang/AST/RecursiveASTVisitor.h"
#include "clang/Basic/DiagnosticOptions.h"
#include "clang/CodeGen/CodeGenAction.h"
#include "clang/Frontend/CompilerInstance.h"
#include "clang/Frontend/CompilerInvocation.h"
#include "clang/Frontend/MultiplexConsumer.h"
#include "clang/Frontend/TextDiagnosticPrinter.h"
#include "llvm/ADT/StringSwitch.h"
#include "llvm/Bitcode/BitcodeReader.h"
#include "llvm/Bitcode/BitcodeWriter.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/LLVMContext.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Verifier.h"
#include "llvm/Analysis/ValueTracking.h"
#include "llvm/Linker/Linker.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/SHA256.h"
#include "llvm/Support/TargetSelect.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Transforms/IPO/AlwaysInliner.h"
#include "llvm/Transforms/IPO/GlobalDCE.h"
#include "llvm/Transforms/Scalar/InferAddressSpaces.h"
#include "llvm/Transforms/Utils/Cloning.h"

#include <functional>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <vector>

using namespace llvm;
namespace ca = clang;

static const char *kAirDataLayout =
    "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-"
    "v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32";

[[noreturn]] static void die(const Twine &msg) {
  errs() << "xtmetal: error: " << msg << "\n";
  exit(1);
}

// ---------------------------------------------------------------------------------------------------------------
// Metadata trees built from the AST and materialized into LLVM metadata after code generation.

struct MD {
  enum Kind { Str, I32, I64, Node, Null, Func, Global } kind = Node;
  std::string s;
  int64_t v = 0;
  std::vector<MD> kids;
  static MD str(const std::string &s) { MD m; m.kind = Str; m.s = s; return m; }
  static MD i32(int64_t v) { MD m; m.kind = I32; m.v = v; return m; }
  static MD node(std::vector<MD> k = {}) { MD m; m.kind = Node; m.kids = std::move(k); return m; }
  static MD null() { MD m; m.kind = Null; return m; }
  static MD func(const std::string &name) { MD m; m.kind = Func; m.s = name; return m; }
  static MD global(const std::string &name) { MD m; m.kind = Global; m.s = name; return m; }
  MD &add(MD m) { kids.push_back(std::move(m)); return *this; }
  MD &add(const std::string &s) { return add(str(s)); }
  MD &add(const char *s) { return add(str(s)); }
  MD &addi(int64_t v) { return add(i32(v)); }
};

static Metadata *materialize(Module &M, const MD &m) {
  LLVMContext &C = M.getContext();
  switch (m.kind) {
  case MD::Str: return MDString::get(C, m.s);
  case MD::I32: return ConstantAsMetadata::get(ConstantInt::get(Type::getInt32Ty(C), m.v));
  case MD::I64: return ConstantAsMetadata::get(ConstantInt::get(Type::getInt64Ty(C), m.v));
  case MD::Null: return nullptr;
  case MD::Func: {
    Function *F = M.getFunction(m.s);
    if (!F) die("internal: missing function " + m.s);
    return ConstantAsMetadata::get(F);
  }
  case MD::Global: {
    GlobalVariable *G = M.getGlobalVariable(m.s, true);
    if (!G) die("internal: missing global " + m.s);
    return ConstantAsMetadata::get(G);
  }
  case MD::Node: {
    std::vector<Metadata *> ops;
    for (auto &k : m.kids) ops.push_back(materialize(M, k));
    return MDNode::get(C, ops);
  }
  }
  return nullptr;
}

// ---------------------------------------------------------------------------------------------------------------
// Entry point descriptions (plain data that outlives the AST).

enum class ScalarKind { None, F32, F16, I1, I8, I16, I32, I64, BF16 };

struct ValueType {     // the IR type of one flattened AIR value
  ScalarKind scalar = ScalarKind::None;
  unsigned vec = 0;    // 0 = scalar
  bool isPtr = false;  // opaque resource pointer
  std::string opaque;  // "struct._texture_2d_t"
  unsigned addrSpace = 0;
  unsigned arrayLen = 0; // for arrays of scalars/vectors (e.g. clip_distance)
};

struct FlatField {     // one AIR argument or return element carved out of a struct in memory
  uint64_t offset = 0;
  ValueType type;
  MD md;               // argument metadata without the leading index (inputs) or as-is (outputs)
};

enum class ArgKind { Direct, Memory };

struct ArgDesc {
  ArgKind kind = ArgKind::Direct;
  uint64_t size = 0, align = 1;   // for Memory args: the size of the in-memory value
  std::vector<FlatField> fields;  // Direct args: one field whose md describes it
  bool isResource = false;
};

enum class EntryKind { Vertex, Fragment, Kernel, Visible, Mesh, Object };

struct EntryDesc {
  EntryKind kind;
  std::string name;      // AIR function name
  std::string mangled;   // clang's name for the user function
  std::vector<ArgDesc> args;
  bool returnsVoid = true;
  uint64_t retSize = 0, retAlign = 1;
  std::vector<FlatField> rets;     // flattened return values
  bool retPacked = false;          // return as a packed struct of all rets
  MD stitching;                    // visible functions: air.stitching_info (empty node if none)
  bool stitchable = false;
  std::vector<std::pair<std::string, ValueType>> stitchTypes; // trait helper functions to generate
  std::vector<std::string> extraAttrs;
};

struct FunctionConstant {
  std::string var;       // mangled name of the global the user code reads
  std::string typeName;  // "bool", "float"...
  std::string name;
  int index;
  ScalarKind scalar;
  unsigned vec;
};

struct CollectResult {
  std::vector<EntryDesc> entries;
  std::vector<FunctionConstant> constants;
  bool error = false;
};

// ---------------------------------------------------------------------------------------------------------------
// AST walking

struct AttrInfo {
  std::string name;               // "buffer", "position", ...
  std::vector<int64_t> ints;
  std::vector<std::string> strs;  // identifier-style arguments (user(x), function_constant(x))
};

static std::vector<AttrInfo> airAttrs(const ca::Decl *D, ca::ASTContext &Ctx) {
  std::vector<AttrInfo> out;
  if (!D) return out;
  for (auto *A : D->specific_attrs<ca::AnnotateAttr>()) {
    StringRef ann = A->getAnnotation();
    if (!ann.startswith("air:")) continue;
    AttrInfo ai;
    ai.name = ann.drop_front(4).str();
    for (ca::Expr *E : A->args()) {
      E = E->IgnoreParenImpCasts();
      if (auto *CE = dyn_cast<ca::ConstantExpr>(E)) {
        if (CE->hasAPValueResult() && CE->getAPValueResult().isInt()) {
          ai.ints.push_back(CE->getAPValueResult().getInt().getSExtValue());
          continue;
        }
        E = CE->getSubExpr()->IgnoreParenImpCasts();
      }
      if (auto *SL = dyn_cast<ca::StringLiteral>(E)) { ai.strs.push_back(SL->getString().str()); continue; }
      ca::Expr::EvalResult R;
      if (E->EvaluateAsInt(R, Ctx)) { ai.ints.push_back(R.Val.getInt().getSExtValue()); continue; }
      ai.strs.push_back("?");
    }
    out.push_back(ai);
  }
  return out;
}

static const AttrInfo *findAttr(const std::vector<AttrInfo> &v, StringRef n) {
  for (auto &a : v) if (a.name == n) return &a;
  return nullptr;
}

class Collector {
public:
  ca::ASTContext &Ctx;
  ca::DiagnosticsEngine &Diags;
  std::unique_ptr<ca::MangleContext> Mangler;
  CollectResult &R;

  Collector(ca::ASTContext &C, CollectResult &R) : Ctx(C), Diags(C.getDiagnostics()), R(R) {
    Mangler.reset(Ctx.createMangleContext());
  }

  void error(ca::SourceLocation L, const Twine &msg) {
    unsigned id = Diags.getCustomDiagID(ca::DiagnosticsEngine::Error, "%0");
    Diags.Report(L, id) << msg.str();
    R.error = true;
  }

  std::string mangle(const ca::NamedDecl *D) {
    if (!Mangler->shouldMangleDeclName(D)) return D->getName().str();
    std::string s;
    raw_string_ostream os(s);
    if (auto *FD = dyn_cast<ca::FunctionDecl>(D)) Mangler->mangleName(ca::GlobalDecl(FD), os);
    else Mangler->mangleName(ca::GlobalDecl(cast<ca::VarDecl>(D)), os);
    return os.str();
  }

  // --- types -----------------------------------------------------------------

  static bool isConstantAS(ca::LangAS AS) {
    return AS == ca::LangAS::opencl_constant || (ca::isTargetAddressSpace(AS) && ca::toTargetAddressSpace(AS) == 2);
  }
  static int airAS(ca::LangAS AS) {
    if (isConstantAS(AS)) return 2;
    if (AS == ca::LangAS::opencl_global || (ca::isTargetAddressSpace(AS) && ca::toTargetAddressSpace(AS) == 1)) return 1;
    if (AS == ca::LangAS::opencl_local || (ca::isTargetAddressSpace(AS) && ca::toTargetAddressSpace(AS) == 3)) return 3;
    return 0;
  }

  static bool isNamespaceMetal(const ca::Decl *D) {
    for (auto *DC = D->getDeclContext(); DC; DC = DC->getParent())
      if (auto *NS = dyn_cast<ca::NamespaceDecl>(DC)) if (NS->getName() == "metal") return true;
    return false;
  }

  ScalarKind scalarKind(ca::QualType T) {
    T = T.getCanonicalType();
    if (auto *ET = T->getAs<ca::EnumType>()) T = ET->getDecl()->getIntegerType().getCanonicalType();
    auto *BT = T->getAs<ca::BuiltinType>();
    if (!BT) return ScalarKind::None;
    switch (BT->getKind()) {
    case ca::BuiltinType::Float: return ScalarKind::F32;
    case ca::BuiltinType::Half: case ca::BuiltinType::Float16: return ScalarKind::F16;
    case ca::BuiltinType::BFloat16: return ScalarKind::BF16;
    case ca::BuiltinType::Bool: return ScalarKind::I1;
    case ca::BuiltinType::Char_S: case ca::BuiltinType::Char_U: case ca::BuiltinType::SChar: case ca::BuiltinType::UChar:
      return ScalarKind::I8;
    case ca::BuiltinType::Short: case ca::BuiltinType::UShort: return ScalarKind::I16;
    case ca::BuiltinType::Int: case ca::BuiltinType::UInt: return ScalarKind::I32;
    case ca::BuiltinType::Long: case ca::BuiltinType::ULong: case ca::BuiltinType::LongLong: case ca::BuiltinType::ULongLong:
      return ScalarKind::I64;
    default: return ScalarKind::None;
    }
  }

  std::string scalarName(ca::QualType T) {
    T = T.getCanonicalType();
    auto *BT = T->getAs<ca::BuiltinType>();
    if (!BT) return "?";
    switch (BT->getKind()) {
    case ca::BuiltinType::Float: return "float";
    case ca::BuiltinType::Half: case ca::BuiltinType::Float16: return "half";
    case ca::BuiltinType::BFloat16: return "bfloat";
    case ca::BuiltinType::Bool: return "bool";
    case ca::BuiltinType::Char_S: case ca::BuiltinType::SChar: return "char";
    case ca::BuiltinType::Char_U: case ca::BuiltinType::UChar: return "uchar";
    case ca::BuiltinType::Short: return "short";
    case ca::BuiltinType::UShort: return "ushort";
    case ca::BuiltinType::Int: return "int";
    case ca::BuiltinType::UInt: return "uint";
    case ca::BuiltinType::Long: case ca::BuiltinType::LongLong: return "long";
    case ca::BuiltinType::ULong: case ca::BuiltinType::ULongLong: return "ulong";
    case ca::BuiltinType::Void: return "void";
    default: return "?";
    }
  }

  // Itanium-style code used by Apple in generated(...) names and stitching trait names.
  std::string mangleCode(ca::QualType T) {
    T = T.getCanonicalType();
    if (auto *VT = T->getAs<ca::ExtVectorType>())
      return "Dv" + std::to_string(VT->getNumElements()) + "_" + mangleCode(VT->getElementType());
    if (auto *PT = T->getAs<ca::PointerType>()) {
      ca::QualType P = PT->getPointeeType();
      std::string as;
      switch (airAS(P.getAddressSpace())) {
      case 1: as = "U9MTLdevice"; break;
      case 2: as = "U11MTLconstant"; break;
      case 3: as = "U14MTLthreadgroup"; break;
      default: as = "U9MTLthread"; break;
      }
      return "P" + as + (P.isConstQualified() ? "K" : "") + mangleCode(P.getUnqualifiedType());
    }
    if (auto *BT = T->getAs<ca::BuiltinType>()) {
      switch (BT->getKind()) {
      case ca::BuiltinType::Float: return "f";
      case ca::BuiltinType::Half: case ca::BuiltinType::Float16: return "Dh";
      case ca::BuiltinType::BFloat16: return "DF16b";
      case ca::BuiltinType::Bool: return "b";
      case ca::BuiltinType::Char_S: case ca::BuiltinType::SChar: return "c";
      case ca::BuiltinType::Char_U: case ca::BuiltinType::UChar: return "h";
      case ca::BuiltinType::Short: return "s";
      case ca::BuiltinType::UShort: return "t";
      case ca::BuiltinType::Int: return "i";
      case ca::BuiltinType::UInt: return "j";
      case ca::BuiltinType::Long: return "l";
      case ca::BuiltinType::ULong: return "m";
      default: break;
      }
    }
    if (auto *RT = T->getAs<ca::RecordType>()) {
      std::string n = RT->getDecl()->getName().str();
      return std::to_string(n.size()) + n;
    }
    return "v";
  }

  std::string accessName(int64_t a) {
    switch (a) { case 0: return "sample"; case 1: return "read"; case 2: return "write"; case 3: return "read_write"; }
    return "sample";
  }

  // Template argument helpers for metal::texture2d<T, access>, metal::matrix<T, C, R>...
  static const ca::TemplateArgumentList *templateArgs(ca::QualType T) {
    if (auto *RD = T.getCanonicalType()->getAsCXXRecordDecl())
      if (auto *S = dyn_cast<ca::ClassTemplateSpecializationDecl>(RD)) return &S->getTemplateArgs();
    return nullptr;
  }

  std::string recordName(const ca::RecordDecl *RD) {
    if (RD->getIdentifier()) {
      std::string q = RD->getQualifiedNameAsString();
      return q;
    }
    if (auto *TD = RD->getTypedefNameForAnonDecl()) return TD->getName().str();
    return "";
  }

  // Resource classes in our metal namespace carry a static marker describing the AIR resource.
  struct ResourceInfo { std::string kind; std::string opaque; unsigned as = 1; std::string base; };
  bool resourceInfo(ca::QualType T, ResourceInfo &ri) {
    auto *RD = T.getCanonicalType()->getAsCXXRecordDecl();
    if (!RD || !isNamespaceMetal(RD)) return false;
    for (auto *A : RD->specific_attrs<ca::AnnotateAttr>()) {
      StringRef ann = A->getAnnotation();
      if (!ann.startswith("xt.resource:")) continue;
      SmallVector<StringRef, 4> parts;
      ann.split(parts, ':');
      ri.kind = parts[1].str();
      ri.opaque = parts[2].str();
      ri.as = std::stoi(parts[3].str());
      ri.base = RD->getName().str();
      return true;
    }
    return false;
  }

  std::string mslName(ca::QualType T) {
    T = T.getCanonicalType();
    if (auto *VT = T->getAs<ca::ExtVectorType>())
      return scalarName(VT->getElementType()) + std::to_string(VT->getNumElements());
    if (auto *PT = T->getAs<ca::PointerType>()) return mslName(PT->getPointeeType());
    if (auto *RT = T->getAs<ca::ReferenceType>()) return mslName(RT->getPointeeType());
    if (auto *AT = dyn_cast<ca::ConstantArrayType>(T.getTypePtr())) return mslName(AT->getElementType());
    if (auto *ET = T->getAs<ca::EnumType>()) return mslName(ET->getDecl()->getIntegerType());
    if (auto *RD = T->getAsCXXRecordDecl()) {
      ResourceInfo ri;
      auto *args = templateArgs(T);
      if (resourceInfo(T, ri)) {
        if (ri.kind == "texture" && args && args->size() >= 2)
          return ri.base + "<" + mslName(args->get(0).getAsType()) + ", " +
                 accessName(args->get(1).getAsIntegral().getSExtValue()) + ">";
        return ri.base;
      }
      if (isNamespaceMetal(RD) && args) {
        StringRef n = RD->getName();
        if (n == "matrix" && args->size() == 3)
          return mslName(args->get(0).getAsType()) + std::to_string(args->get(1).getAsIntegral().getSExtValue()) + "x" +
                 std::to_string(args->get(2).getAsIntegral().getSExtValue());
        if (n == "packed_vec" && args->size() == 2)
          return "packed_" + mslName(args->get(0).getAsType()) + std::to_string(args->get(1).getAsIntegral().getSExtValue());
        if (n == "array" && args->size() == 2) return mslName(args->get(0).getAsType());
      }
      return recordName(RD);
    }
    return scalarName(T);
  }

  bool valueType(ca::QualType T, ValueType &vt) {
    T = T.getCanonicalType();
    if (auto *VT = T->getAs<ca::ExtVectorType>()) {
      vt.scalar = scalarKind(VT->getElementType());
      vt.vec = VT->getNumElements();
      return vt.scalar != ScalarKind::None;
    }
    if (auto *AT = dyn_cast<ca::ConstantArrayType>(T.getTypePtr())) {
      if (!valueType(AT->getElementType(), vt)) return false;
      vt.arrayLen = AT->getSize().getZExtValue();
      return true;
    }
    vt.scalar = scalarKind(T);
    return vt.scalar != ScalarKind::None;
  }

  uint64_t sizeOf(ca::QualType T) { return Ctx.getTypeSizeInChars(T).getQuantity(); }
  uint64_t alignOf(ca::QualType T) { return Ctx.getTypeAlignInChars(T).getQuantity(); }

  bool isArgumentBufferStruct(const ca::RecordDecl *RD) {
    for (auto *F : RD->fields()) {
      if (findAttr(airAttrs(F, Ctx), "id")) return true;
      ResourceInfo ri;
      if (resourceInfo(F->getType(), ri)) return true;
      if (F->getType()->isPointerType()) return true;
    }
    return false;
  }

  // air.struct_type_info for a record (recursive), optionally with argument-buffer descriptions.
  MD structInfo(const ca::RecordDecl *RD, bool argBuffer) {
    MD n = MD::node();
    const ca::ASTRecordLayout &L = Ctx.getASTRecordLayout(RD);
    int fieldIndex = 0;
    std::vector<const ca::FieldDecl *> fields;
    if (auto *CXX = dyn_cast<ca::CXXRecordDecl>(RD))
      for (auto &B : CXX->bases()) { (void)B; } // bases are rare in MSL buffer structs
    for (auto *F : RD->fields()) {
      uint64_t off = L.getFieldOffset(fieldIndex++) / 8;
      ca::QualType FT = F->getType().getCanonicalType();
      uint64_t count = 0;
      ca::QualType ET = FT;
      if (auto *AT = dyn_cast<ca::ConstantArrayType>(FT.getTypePtr())) {
        count = AT->getSize().getZExtValue();
        ET = AT->getElementType().getCanonicalType();
      }
      ResourceInfo ri;
      bool isRes = resourceInfo(ET, ri);
      auto *FRD = ET->getAsRecordDecl();
      bool special = FRD && (isRes || (isNamespaceMetal(FRD) && templateArgs(ET)));
      if (FRD && !special) n.add("air.struct_type_info").add(structInfo(FRD, argBuffer && isArgumentBufferStruct(FRD)));
      uint64_t sz = ET->isPointerType() ? 8 : sizeOf(ET);
      n.addi(off).addi(sz).addi(count).add(mslName(ET)).add(F->getName().str());
      if (argBuffer) {
        auto attrs = airAttrs(F, Ctx);
        auto *id = findAttr(attrs, "id");
        int64_t loc = id && !id->ints.empty() ? id->ints[0] : fieldIndex - 1;
        MD ia = MD::node();
        ia.addi(loc);
        if (isRes) {
          if (ri.kind == "texture") {
            ia.add("air.texture").add("air.location_index").addi(loc).addi(1);
            auto *args = templateArgs(ET);
            ia.add("air." + accessName(args && args->size() >= 2 ? args->get(1).getAsIntegral().getSExtValue() : 0));
          } else if (ri.kind == "sampler") {
            ia.add("air.sampler").add("air.location_index").addi(loc).addi(1);
          } else {
            ia.add("air." + ri.kind).add("air.location_index").addi(loc).addi(1);
          }
          ia.add("air.arg_type_name").add(mslName(ET)).add("air.arg_name").add(F->getName().str());
        } else if (ET->isPointerType()) {
          ca::QualType P = ET->getPointeeType();
          ia.add("air.buffer").add("air.location_index").addi(loc).addi(1);
          bool ro = isConstantAS(P.getAddressSpace()) || P.isConstQualified();
          ia.add(ro ? "air.read" : "air.read_write");
          if (auto *PRD = P->getAsRecordDecl())
            if (!templateArgs(P)) ia.add("air.struct_type_info").add(structInfo(PRD, false));
          ia.add("air.arg_type_size").addi(sizeOf(P)).add("air.arg_type_align_size").addi(alignOf(P));
          ia.add("air.arg_type_name").add(mslName(P)).add("air.arg_name").add(F->getName().str());
        } else {
          ia.add("air.indirect_constant").add("air.location_index").addi(loc).addi(1);
          ia.add("air.arg_type_name").add(mslName(ET)).add("air.arg_name").add(F->getName().str());
        }
        n.add("air.indirect_argument").add(ia);
      }
    }
    return n;
  }

  // --- stitching descriptions -----------------------------------------------------------------

  MD airTypeDesc(ca::QualType T) {
    T = T.getCanonicalType();
    if (auto *VT = T->getAs<ca::ExtVectorType>()) {
      return MD::node({MD::str("air.vector_type"), MD::i32(sizeOf(T)), MD::i32(alignOf(T)), MD::null(),
                       airTypeDesc(VT->getElementType()), MD::i32(VT->getNumElements())});
    }
    if (auto *PT = T->getAs<ca::PointerType>()) {
      ca::QualType P = PT->getPointeeType();
      MD inner = airTypeDesc(P.getUnqualifiedType());
      int as = airAS(P.getAddressSpace());
      inner.kids[3] = MD::node({MD::node({MD::str("air.address_space"), MD::i32(as)})});
      return MD::node({MD::str("air.pointer_type"), MD::i32(8), MD::i32(8), MD::null(), inner});
    }
    std::string k;
    switch (scalarKind(T)) {
    case ScalarKind::F32: k = "air.float_type"; break;
    case ScalarKind::F16: k = "air.half_type"; break;
    case ScalarKind::BF16: k = "air.bfloat_type"; break;
    case ScalarKind::I1: k = "air.bool_type"; break;
    case ScalarKind::I8: k = T->isSignedIntegerType() ? "air.char_type" : "air.uchar_type"; break;
    case ScalarKind::I16: k = T->isSignedIntegerType() ? "air.short_type" : "air.ushort_type"; break;
    case ScalarKind::I32: k = T->isSignedIntegerType() ? "air.int_type" : "air.uint_type"; break;
    case ScalarKind::I64: k = T->isSignedIntegerType() ? "air.long_type" : "air.ulong_type"; break;
    default: k = "air.unknown_type";
    }
    return MD::node({MD::str(k), MD::i32(sizeOf(T)), MD::i32(alignOf(T)), MD::null()});
  }

  MD stitchingType(EntryDesc &E, ca::QualType T) {
    std::string code = mangleCode(T);
    std::string base = "_ZN5metal22_stitching_traits_implI" + code + "E";
    ValueType vt;
    T = T.getCanonicalType();
    if (auto *PT = T->getAs<ca::PointerType>()) {
      vt.isPtr = true;
      vt.addrSpace = airAS(PT->getPointeeType().getAddressSpace());
      vt.opaque = "ptr:" + code;
    } else if (!valueType(T, vt)) {
      return MD::null();
    }
    bool have = false;
    for (auto &st : E.stitchTypes) if (st.first == base) have = true;
    if (!have) E.stitchTypes.push_back({base, vt});
    std::string ret = (vt.isPtr ? "S2_" : (vt.vec ? "S1_" : code));
    return MD::node({MD::str("air.stitching_type"), airTypeDesc(T), MD::func(base + "13load_argumentEPv"),
                     MD::func(base + "18store_return_valueEPv" + ret), MD::func(base + "7destroyEPv"),
                     MD::func(base + "16copy_from_bufferEPvPU11MTLconstantKv")});
  }

  // --- entry points ----------------------------------------------------------------------------

  void interpolation(const std::vector<AttrInfo> &attrs, ca::QualType T, MD &m, bool isPosition) {
    if (isPosition) { m.add("air.center").add("air.no_perspective"); return; }
    static const std::pair<const char *, std::pair<const char *, const char *>> table[] = {
        {"flat", {"air.flat", nullptr}},
        {"center_perspective", {"air.center", "air.perspective"}},
        {"center_no_perspective", {"air.center", "air.no_perspective"}},
        {"centroid_perspective", {"air.centroid", "air.perspective"}},
        {"centroid_no_perspective", {"air.centroid", "air.no_perspective"}},
        {"sample_perspective", {"air.sample", "air.perspective"}},
        {"sample_no_perspective", {"air.sample", "air.no_perspective"}},
    };
    for (auto &t : table)
      if (findAttr(attrs, t.first)) {
        m.add(t.second.first);
        if (t.second.second) m.add(t.second.second);
        return;
      }
    ca::QualType S = T.getCanonicalType();
    if (auto *VT = S->getAs<ca::ExtVectorType>()) S = VT->getElementType();
    if (!S->isFloatingType()) { m.add("air.flat"); return; }
    m.add("air.center").add("air.perspective");
  }

  std::string varyingName(const std::vector<AttrInfo> &attrs, const ca::FieldDecl *F) {
    if (auto *u = findAttr(attrs, "user")) return "user(" + (u->strs.empty() ? std::string("?") : u->strs[0]) + ")";
    std::string n = F->getName().str();
    return "generated(" + std::to_string(n.size()) + n + mangleCode(F->getType()) + ")";
  }

  // Flatten a struct used as vertex/fragment stage_in or as a vertex/fragment return value.
  void flattenStruct(const ca::RecordDecl *RD, uint64_t base, EntryKind kind, bool isInput,
                     std::vector<FlatField> &out, ca::SourceLocation loc) {
    const ca::ASTRecordLayout &L = Ctx.getASTRecordLayout(RD);
    int idx = 0;
    for (auto *F : RD->fields()) {
      uint64_t off = base + L.getFieldOffset(idx++) / 8;
      auto attrs = airAttrs(F, Ctx);
      ca::QualType FT = F->getType();
      if (auto *NRD = FT.getCanonicalType()->getAsRecordDecl()) {
        if (!templateArgs(FT)) { flattenStruct(NRD, off, kind, isInput, out, F->getLocation()); continue; }
      }
      FlatField ff;
      ff.offset = off;
      if (!valueType(FT, ff.type)) { error(F->getLocation(), "unsupported field type in stage_in/output struct"); continue; }
      std::string tn = mslName(FT), fn = F->getName().str();
      MD m = MD::node();
      if (kind == EntryKind::Vertex && isInput) {
        auto *a = findAttr(attrs, "attribute");
        m.add("air.vertex_input").add("air.location_index").addi(a && !a->ints.empty() ? a->ints[0] : 0).addi(1);
      } else if (kind == EntryKind::Vertex && !isInput) {
        if (findAttr(attrs, "position")) m.add("air.position");
        else if (findAttr(attrs, "point_size")) m.add("air.point_size");
        else if (findAttr(attrs, "clip_distance")) m.add("air.clip_distance");
        else if (findAttr(attrs, "render_target_array_index")) m.add("air.render_target_array_index");
        else if (findAttr(attrs, "viewport_array_index")) m.add("air.viewport_array_index");
        else if (findAttr(attrs, "invariant") && findAttr(attrs, "position")) m.add("air.position").add("air.invariant");
        else m.add("air.vertex_output").add(varyingName(attrs, F));
      } else if (kind == EntryKind::Fragment && isInput) {
        if (findAttr(attrs, "position")) { m.add("air.position"); interpolation(attrs, FT, m, true); }
        else if (findAttr(attrs, "render_target_array_index")) m.add("air.render_target_array_index");
        else if (findAttr(attrs, "viewport_array_index")) m.add("air.viewport_array_index");
        else if (findAttr(attrs, "point_size") || findAttr(attrs, "clip_distance")) continue;
        else { m.add("air.fragment_input").add(varyingName(attrs, F)); interpolation(attrs, FT, m, false); }
      } else if (kind == EntryKind::Fragment && !isInput) {
        if (auto *c = findAttr(attrs, "color")) {
          auto *ix = findAttr(attrs, "index");
          m.add("air.render_target").addi(c->ints.empty() ? 0 : c->ints[0]).addi(ix && !ix->ints.empty() ? ix->ints[0] : 0);
        } else if (auto *d = findAttr(attrs, "depth")) {
          std::string q = d->strs.empty() ? "any" : d->strs[0];
          m.add("air.depth").add("air.depth_qualifier").add("air." + q);
        } else if (findAttr(attrs, "sample_mask")) m.add("air.sample_mask");
        else if (findAttr(attrs, "stencil")) m.add("air.stencil");
        else { error(F->getLocation(), "fragment output field '" + fn + "' needs [[color(n)]], [[depth]] or [[sample_mask]]"); continue; }
      }
      m.add("air.arg_type_name").add(tn).add("air.arg_name").add(fn);
      ff.md = m;
      out.push_back(ff);
    }
    (void)loc;
  }

  void buildEntry(const ca::FunctionDecl *FD, EntryKind kind, const std::vector<AttrInfo> &fattrs) {
    EntryDesc E;
    E.kind = kind;
    E.mangled = mangle(FD);
    E.name = FD->getName().str();
    if (auto *hn = findAttr(fattrs, "host_name")) if (!hn->strs.empty()) E.name = hn->strs[0];
    E.stitchable = findAttr(fattrs, "stitchable") != nullptr;
    int airIndex = 0;
    MD stitchArgs = MD::node();

    for (auto *P : FD->parameters()) {
      auto attrs = airAttrs(P, Ctx);
      ca::QualType T = P->getType();
      std::string pname = P->getName().str();
      ArgDesc A;
      ResourceInfo ri;
      ca::QualType CT = T.getCanonicalType();
      if (findAttr(attrs, "stage_in")) {
        auto *RD = CT->getAsRecordDecl();
        if (!RD) { error(P->getLocation(), "[[stage_in]] requires a struct"); continue; }
        A.kind = ArgKind::Memory;
        A.size = sizeOf(CT);
        A.align = alignOf(CT);
        flattenStruct(RD, 0, kind, true, A.fields, P->getLocation());
        for (auto &f : A.fields) { MD m = MD::node({MD::i32(airIndex++)}); for (auto &k : f.md.kids) m.add(k); f.md = m; }
        E.args.push_back(A);
        continue;
      }
      if (kind == EntryKind::Visible) {
        FlatField ff;
        MD m = MD::node({MD::i32(airIndex++), MD::str("air.visible_input")});
        m.add("air.arg_type_name").add(mslName(T)).add("air.arg_name").add(pname);
        ff.md = m;
        if (resourceInfo(CT, ri)) {
          A.kind = ArgKind::Memory; A.isResource = true; A.size = sizeOf(CT); A.align = alignOf(CT);
          ff.type.isPtr = true; ff.type.opaque = "struct." + ri.opaque; ff.type.addrSpace = ri.as;
        } else if (!CT->isPointerType() && !CT->isReferenceType()) {
          if (!valueType(CT, ff.type)) {
            A.kind = ArgKind::Memory; A.size = sizeOf(CT); A.align = alignOf(CT);
          }
        }
        A.fields.push_back(ff);
        E.args.push_back(A);
        if (E.stitchable) stitchArgs.add(MD::node({MD::str("air.stitching_argument"), stitchingType(E, T), MD::str(pname)}));
        continue;
      }
      FlatField ff;
      MD m = MD::node({MD::i32(airIndex++)});
      if (resourceInfo(CT, ri)) {
        A.kind = ArgKind::Memory; A.isResource = true; A.size = sizeOf(CT); A.align = alignOf(CT);
        ff.type.isPtr = true; ff.type.opaque = "struct." + ri.opaque; ff.type.addrSpace = ri.as;
        const char *which = ri.kind == "texture" ? "texture" : ri.kind == "sampler" ? "sampler" : nullptr;
        auto *loc = which ? findAttr(attrs, which) : nullptr;
        m.add("air." + ri.kind).add("air.location_index").addi(loc && !loc->ints.empty() ? loc->ints[0] : 0).addi(1);
        if (ri.kind == "texture") {
          auto *args = templateArgs(CT);
          m.add("air." + accessName(args && args->size() >= 2 ? args->get(1).getAsIntegral().getSExtValue() : 0));
        }
        m.add("air.arg_type_name").add(mslName(CT)).add("air.arg_name").add(pname);
      } else if (CT->isPointerType() || CT->isReferenceType()) {
        ca::QualType Pt = CT->getPointeeType();
        bool isRef = CT->isReferenceType();
        auto *buf = findAttr(attrs, "buffer");
        auto *tg = findAttr(attrs, "threadgroup");
        int64_t loc = buf && !buf->ints.empty() ? buf->ints[0] : tg && !tg->ints.empty() ? tg->ints[0] : 0;
        auto *PRD = Pt.getCanonicalType()->getAsRecordDecl();
        bool indirect = PRD && !templateArgs(Pt) && isArgumentBufferStruct(PRD);
        m.add(indirect ? "air.indirect_buffer" : "air.buffer");
        if (isRef) m.add("air.buffer_size").addi(sizeOf(Pt));
        m.add("air.location_index").addi(loc).addi(1);
        bool ro = isConstantAS(Pt.getAddressSpace()) || Pt.isConstQualified();
        m.add(ro ? "air.read" : "air.read_write");
        if (PRD && (!templateArgs(Pt) || mslName(Pt) == "metal::_atomic")) m.add("air.struct_type_info").add(structInfo(PRD, indirect));
        m.add("air.arg_type_size").addi(sizeOf(Pt)).add("air.arg_type_align_size").addi(alignOf(Pt));
        m.add("air.arg_type_name").add(mslName(Pt)).add("air.arg_name").add(pname);
        ff.type.isPtr = true; // passed through with the user function's IR type
      } else {
        if (!valueType(CT, ff.type)) { error(P->getLocation(), "unsupported entry point parameter type"); continue; }
        // builtin inputs
        if (attrs.empty()) { error(P->getLocation(), "entry point parameter '" + pname + "' has no attribute"); continue; }
        const AttrInfo &a = attrs[0];
        if (kind == EntryKind::Fragment && a.name == "position") { m.add("air.position"); interpolation(attrs, CT, m, true); }
        else if (kind == EntryKind::Fragment && a.name == "color") m.add("air.render_target").addi(a.ints.empty() ? 0 : a.ints[0]);
        else m.add("air." + a.name);
        m.add("air.arg_type_name").add(mslName(CT)).add("air.arg_name").add(pname);
      }
      ff.md = m;
      A.fields.push_back(ff);
      E.args.push_back(A);
    }

    // return value
    ca::QualType RT = FD->getReturnType().getCanonicalType();
    if (!RT->isVoidType()) {
      E.returnsVoid = false;
      E.retSize = sizeOf(RT);
      E.retAlign = alignOf(RT);
      if (kind == EntryKind::Visible) {
        FlatField ff;
        if (!valueType(RT, ff.type)) error(FD->getLocation(), "unsupported visible function return type");
        ff.md = MD::node({MD::str("air.visible_output"), MD::str("air.arg_type_name"), MD::str(mslName(RT))});
        E.rets.push_back(ff);
      } else if (auto *RD = RT->getAsRecordDecl(); RD && !templateArgs(RT)) {
        flattenStruct(RD, 0, kind, false, E.rets, FD->getLocation());
        E.retPacked = true;
      } else {
        FlatField ff;
        if (!valueType(RT, ff.type)) error(FD->getLocation(), "unsupported entry point return type");
        if (kind == EntryKind::Fragment) ff.md = MD::node({MD::str("air.render_target"), MD::i32(0), MD::i32(0),
                                                          MD::str("air.arg_type_name"), MD::str(mslName(RT))});
        else if (kind == EntryKind::Vertex) { ff.md = MD::node({MD::str("air.position"), MD::str("air.arg_type_name"), MD::str(mslName(RT))}); E.retPacked = true; }
        E.rets.push_back(ff);
      }
    }
    if (E.stitchable) {
      MD si = MD::node({MD::str("air.stitching_info")});
      si.add(RT->isVoidType() ? MD::null() : stitchingType(E, RT));
      for (auto &k : stitchArgs.kids) si.add(k);
      E.stitching = si;
    }
    R.entries.push_back(std::move(E));
  }

  void visitFunction(const ca::FunctionDecl *FD) {
    if (!FD->doesThisDeclarationHaveABody()) return;
    if (FD->isDependentContext()) return;
    auto attrs = airAttrs(FD, Ctx);
    for (auto &a : attrs) {
      EntryKind k;
      if (a.name == "vertex") k = EntryKind::Vertex;
      else if (a.name == "fragment") k = EntryKind::Fragment;
      else if (a.name == "kernel") k = EntryKind::Kernel;
      else if (a.name == "visible" || a.name == "stitchable") k = EntryKind::Visible;
      else if (a.name == "mesh") k = EntryKind::Mesh;
      else if (a.name == "object") k = EntryKind::Object;
      else continue;
      buildEntry(FD, k, attrs);
      return;
    }
  }

  void visitVar(const ca::VarDecl *VD) {
    auto attrs = airAttrs(VD, Ctx);
    auto *fc = findAttr(attrs, "function_constant");
    if (!fc) return;
    FunctionConstant c;
    c.var = mangle(VD);
    c.name = VD->getName().str();
    c.index = fc->ints.empty() ? 0 : fc->ints[0];
    c.typeName = mslName(VD->getType());
    ValueType vt;
    valueType(VD->getType(), vt);
    c.scalar = vt.scalar;
    c.vec = vt.vec;
    R.constants.push_back(c);
  }

  void walk(const ca::DeclContext *DC) {
    for (auto *D : DC->decls()) {
      if (auto *NS = dyn_cast<ca::NamespaceDecl>(D)) { if (NS->getName() != "metal" && NS->getName() != "__xt") walk(NS); continue; }
      if (auto *LS = dyn_cast<ca::LinkageSpecDecl>(D)) { walk(LS); continue; }
      if (auto *FT = dyn_cast<ca::FunctionTemplateDecl>(D)) {
        for (auto *S : FT->specializations()) visitFunction(S);
        continue;
      }
      if (auto *FD = dyn_cast<ca::FunctionDecl>(D)) { visitFunction(FD); continue; }
      if (auto *VD = dyn_cast<ca::VarDecl>(D)) { visitVar(VD); continue; }
    }
  }
};

class CollectorConsumer : public ca::ASTConsumer {
  CollectResult &R;
public:
  explicit CollectorConsumer(CollectResult &R) : R(R) {}
  void HandleTranslationUnit(ca::ASTContext &Ctx) override {
    if (Ctx.getDiagnostics().hasErrorOccurred()) return;
    Collector C(Ctx, R);
    C.walk(Ctx.getTranslationUnitDecl());
  }
};

class XtAction : public ca::EmitLLVMOnlyAction {
  CollectResult &R;
public:
  XtAction(LLVMContext *C, CollectResult &R) : ca::EmitLLVMOnlyAction(C), R(R) {}
  std::unique_ptr<ca::ASTConsumer> CreateASTConsumer(ca::CompilerInstance &CI, StringRef InFile) override {
    std::vector<std::unique_ptr<ca::ASTConsumer>> v;
    v.push_back(ca::EmitLLVMOnlyAction::CreateASTConsumer(CI, InFile));
    v.push_back(std::make_unique<CollectorConsumer>(R));
    return std::make_unique<ca::MultiplexConsumer>(std::move(v));
  }
};

// ---------------------------------------------------------------------------------------------------------------
// Lowering

static Type *irScalar(LLVMContext &C, ScalarKind k) {
  switch (k) {
  case ScalarKind::F32: return Type::getFloatTy(C);
  case ScalarKind::F16: return Type::getHalfTy(C);
  case ScalarKind::BF16: return Type::getBFloatTy(C);
  case ScalarKind::I1: return Type::getInt1Ty(C);
  case ScalarKind::I8: return Type::getInt8Ty(C);
  case ScalarKind::I16: return Type::getInt16Ty(C);
  case ScalarKind::I32: return Type::getInt32Ty(C);
  case ScalarKind::I64: return Type::getInt64Ty(C);
  default: return nullptr;
  }
}

static Type *irType(Module &M, const ValueType &vt) {
  LLVMContext &C = M.getContext();
  Type *T;
  if (vt.isPtr) {
    StructType *ST = StructType::getTypeByName(C, vt.opaque);
    if (!ST) ST = StructType::create(C, vt.opaque);
    T = PointerType::get(ST, vt.addrSpace);
  } else {
    T = irScalar(C, vt.scalar);
    if (vt.vec) T = FixedVectorType::get(T, vt.vec);
  }
  if (vt.arrayLen) T = ArrayType::get(T, vt.arrayLen);
  return T;
}

// In-memory type of a value (bool is stored as i8).
static Type *memType(Module &M, const ValueType &vt) {
  if (!vt.isPtr && vt.scalar == ScalarKind::I1) {
    ValueType m = vt;
    m.scalar = ScalarKind::I8;
    return irType(M, m);
  }
  return irType(M, vt);
}

static Value *storeAt(IRBuilder<> &B, Value *base, uint64_t off, Value *v, Type *memTy) {
  Value *p = B.CreateConstInBoundsGEP1_64(B.getInt8Ty(), base, off);
  if (v->getType() != memTy) {
    if (v->getType()->isIntOrIntVectorTy(1)) v = B.CreateZExt(v, memTy);
  }
  p = B.CreateBitCast(p, PointerType::get(memTy, 0));
  return B.CreateStore(v, p);
}

static Value *loadAt(IRBuilder<> &B, Value *base, uint64_t off, Type *memTy, Type *valTy) {
  Value *p = B.CreateConstInBoundsGEP1_64(B.getInt8Ty(), base, off);
  p = B.CreateBitCast(p, PointerType::get(memTy, 0));
  Value *v = B.CreateLoad(memTy, p);
  if (valTy != memTy && valTy->isIntOrIntVectorTy(1)) v = B.CreateTrunc(v, valTy);
  return v;
}

static Value *allocaBytes(IRBuilder<> &B, Function *F, uint64_t size, uint64_t align) {
  IRBuilder<> EB(&F->getEntryBlock(), F->getEntryBlock().begin());
  AllocaInst *A = EB.CreateAlloca(ArrayType::get(EB.getInt8Ty(), std::max<uint64_t>(size, 1)));
  A->setAlignment(Align(std::max<uint64_t>(align, 1)));
  return EB.CreateBitCast(A, EB.getInt8PtrTy());
}

static void genStitchTraits(Module &M, const std::string &base, const ValueType &vt, const std::string &code) {
  LLVMContext &C = M.getContext();
  Type *T;
  if (vt.isPtr) {
    // pointer types: element type is not needed for the traits beyond the pointer itself
    T = PointerType::get(Type::getFloatTy(C), vt.addrSpace);
  } else {
    T = irType(M, vt);
  }
  (void)code;
  Type *i8p = Type::getInt8PtrTy(C);
  Type *cp = Type::getInt8PtrTy(C, 2);
  auto mk = [&](const std::string &n, FunctionType *FT) {
    Function *F = M.getFunction(n);
    if (F) return F;
    F = Function::Create(FT, GlobalValue::LinkOnceODRLinkage, n, M);
    F->setVisibility(GlobalValue::HiddenVisibility);
    return F;
  };
  return (void)mk, (void)T, (void)i8p, (void)cp;
}

struct Lowering {
  Module &M;
  bool fastMath;
  Lowering(Module &M, bool fast) : M(M), fastMath(fast) {}

  Function *lowerEntry(EntryDesc &E) {
    LLVMContext &C = M.getContext();
    Function *U = M.getFunction(E.mangled);
    if (!U) die("entry point '" + E.name + "' was not emitted (mangled " + E.mangled + ")");
    U->setName("__xt_user." + E.name);
    U->setLinkage(GlobalValue::InternalLinkage);
    U->removeFnAttr(Attribute::NoInline);
    U->removeFnAttr(Attribute::OptimizeNone);
    U->addFnAttr(Attribute::AlwaysInline);

    bool sret = U->arg_size() > 0 && U->hasParamAttribute(0, Attribute::StructRet);
    unsigned uarg = sret ? 1 : 0;

    // AIR parameter types
    std::vector<Type *> params;
    std::vector<std::pair<unsigned, unsigned>> argMap; // (desc index, field index) per AIR arg
    for (unsigned i = 0; i < E.args.size(); ++i) {
      auto &A = E.args[i];
      if (A.kind == ArgKind::Direct) {
        Type *T = A.fields[0].type.isPtr ? U->getFunctionType()->getParamType(uarg + i) : irType(M, A.fields[0].type);
        params.push_back(T);
        argMap.push_back({i, 0});
      } else {
        for (unsigned f = 0; f < A.fields.size(); ++f) {
          params.push_back(irType(M, A.fields[f].type));
          argMap.push_back({i, f});
        }
      }
    }
    Type *retTy = Type::getVoidTy(C);
    std::vector<Type *> retElems;
    for (auto &r : E.rets) retElems.push_back(irType(M, r.type));
    if (!E.returnsVoid) {
      if (E.retPacked) retTy = StructType::get(C, retElems, true);
      else retTy = retElems[0];
    }
    FunctionType *FT = FunctionType::get(retTy, params, false);
    Function *F = Function::Create(FT, GlobalValue::ExternalLinkage, E.name, M);
    F->addFnAttr(Attribute::NoUnwind);
    if (fastMath) {
      for (const char *a : {"approx-func-fp-math", "no-infs-fp-math", "no-nans-fp-math", "no-signed-zeros-fp-math", "unsafe-fp-math"})
        F->addFnAttr(a, "true");
    }
    BasicBlock *BB = BasicBlock::Create(C, "entry", F);
    IRBuilder<> B(BB);

    // Build the user call arguments.
    std::vector<Value *> callArgs;
    Value *retMem = nullptr;
    if (sret) {
      Type *ST = U->getParamStructRetType(0);
      retMem = allocaBytes(B, F, std::max<uint64_t>(E.retSize, M.getDataLayout().getTypeAllocSize(ST)), E.retAlign);
      callArgs.push_back(B.CreateBitCast(retMem, U->getFunctionType()->getParamType(0)));
    }
    unsigned airArg = 0;
    for (unsigned i = 0; i < E.args.size(); ++i) {
      auto &A = E.args[i];
      Type *UT = U->getFunctionType()->getParamType(uarg + i);
      if (A.kind == ArgKind::Direct) {
        Value *v = F->getArg(airArg++);
        if (v->getType() != UT) {
          if (UT->isIntOrIntVectorTy() && v->getType()->isIntOrIntVectorTy(1)) v = B.CreateZExt(v, UT);
          else if (UT->isPointerTy() && v->getType()->isPointerTy()) v = B.CreatePointerBitCastOrAddrSpaceCast(v, UT);
          else {
            Value *mem = allocaBytes(B, F, M.getDataLayout().getTypeAllocSize(v->getType()), 16);
            storeAt(B, mem, 0, v, v->getType());
            v = B.CreateLoad(UT, B.CreateBitCast(mem, PointerType::get(UT, 0)));
          }
        }
        callArgs.push_back(v);
        continue;
      }
      Value *mem = allocaBytes(B, F, A.size, A.align);
      for (auto &f : A.fields) {
        Value *v = F->getArg(airArg++);
        storeAt(B, mem, f.offset, v, memType(M, f.type));
      }
      if (U->hasParamAttribute(uarg + i, Attribute::ByVal) || UT->isPointerTy()) {
        callArgs.push_back(B.CreatePointerBitCastOrAddrSpaceCast(mem, UT));
      } else {
        callArgs.push_back(B.CreateLoad(UT, B.CreateBitCast(mem, PointerType::get(UT, 0))));
      }
    }
    CallInst *CI = B.CreateCall(U, callArgs);
    CI->setCallingConv(U->getCallingConv());
    if (sret) CI->addParamAttr(0, Attribute::getWithStructRetType(C, U->getParamStructRetType(0)));
    for (unsigned i = 0; i < U->arg_size(); ++i)
      if (U->hasParamAttribute(i, Attribute::ByVal))
        CI->addParamAttr(i, Attribute::getWithByValType(C, U->getParamByValType(i)));

    if (E.returnsVoid) {
      B.CreateRetVoid();
    } else {
      if (!sret) {
        Type *UR = U->getReturnType();
        retMem = allocaBytes(B, F, std::max<uint64_t>(E.retSize, M.getDataLayout().getTypeAllocSize(UR)), std::max<uint64_t>(E.retAlign, 16));
        B.CreateStore(CI, B.CreateBitCast(retMem, PointerType::get(UR, 0)));
      }
      if (E.retPacked) {
        Value *agg = UndefValue::get(retTy);
        for (unsigned r = 0; r < E.rets.size(); ++r) {
          Value *v = loadAt(B, retMem, E.rets[r].offset, memType(M, E.rets[r].type), retElems[r]);
          agg = B.CreateInsertValue(agg, v, r);
        }
        B.CreateRet(agg);
      } else {
        B.CreateRet(loadAt(B, retMem, 0, memType(M, E.rets[0].type), retTy));
      }
    }
    return F;
  }

  void stitchTraits(EntryDesc &E) {
    LLVMContext &C = M.getContext();
    Type *i8p = Type::getInt8PtrTy(C);
    Type *cp = Type::getInt8PtrTy(C, 2);
    for (auto &st : E.stitchTypes) {
      const std::string &base = st.first;
      Type *T;
      if (st.second.isPtr) T = PointerType::get(Type::getFloatTy(C), st.second.addrSpace);
      else T = irType(M, st.second);
      Type *MT = st.second.isPtr ? T : memType(M, st.second);
      std::string retSuffix = st.second.isPtr ? "S2_" : (st.second.vec ? "S1_" : base.substr(base.find("implI") + 5, base.size() - base.find("implI") - 6));
      auto mk = [&](const std::string &n, FunctionType *FT) -> Function * {
        if (Function *F = M.getFunction(n)) return nullptr;
        Function *F = Function::Create(FT, GlobalValue::LinkOnceODRLinkage, n, M);
        F->setVisibility(GlobalValue::HiddenVisibility);
        F->addFnAttr(Attribute::NoUnwind);
        return F;
      };
      if (Function *F = mk(base + "13load_argumentEPv", FunctionType::get(T, {i8p}, false))) {
        IRBuilder<> B(BasicBlock::Create(C, "", F));
        Value *v = B.CreateLoad(MT, B.CreateBitCast(F->getArg(0), PointerType::get(MT, 0)));
        if (MT != T) v = B.CreateTrunc(v, T);
        B.CreateRet(v);
      }
      if (Function *F = mk(base + "18store_return_valueEPv" + retSuffix, FunctionType::get(Type::getVoidTy(C), {i8p, T}, false))) {
        IRBuilder<> B(BasicBlock::Create(C, "", F));
        Value *v = F->getArg(1);
        if (MT != T) v = B.CreateZExt(v, MT);
        B.CreateStore(v, B.CreateBitCast(F->getArg(0), PointerType::get(MT, 0)));
        B.CreateRetVoid();
      }
      if (Function *F = mk(base + "7destroyEPv", FunctionType::get(Type::getVoidTy(C), {i8p}, false))) {
        IRBuilder<> B(BasicBlock::Create(C, "", F));
        B.CreateRetVoid();
      }
      if (Function *F = mk(base + "16copy_from_bufferEPvPU11MTLconstantKv", FunctionType::get(Type::getVoidTy(C), {i8p, cp}, false))) {
        IRBuilder<> B(BasicBlock::Create(C, "", F));
        uint64_t sz = M.getDataLayout().getTypeStoreSize(MT);
        Value *v = B.CreateLoad(MT, B.CreateBitCast(F->getArg(1), PointerType::get(MT, 2)));
        B.CreateStore(v, B.CreateBitCast(F->getArg(0), PointerType::get(MT, 0)));
        (void)sz;
        B.CreateRetVoid();
      }
    }
  }
};

// Convert LLVM conversion instructions into air.convert calls (Metal conversion semantics: saturating
// float->int, round-to-nearest-even).
static std::string airTypeSuffix(Type *T) {
  std::string s;
  if (auto *VT = dyn_cast<FixedVectorType>(T)) {
    s = "v" + std::to_string(VT->getNumElements());
    T = VT->getElementType();
  }
  if (T->isFloatTy()) return s + "f32";
  if (T->isHalfTy()) return s + "f16";
  if (T->isBFloatTy()) return s + "bf16";
  if (T->isIntegerTy()) return s + "i" + std::to_string(T->getIntegerBitWidth());
  return s + "?";
}

static void lowerConversions(Module &M) {
  std::vector<Instruction *> work;
  for (Function &F : M)
    for (Instruction &I : instructions(F))
      if (isa<FPToSIInst>(I) || isa<FPToUIInst>(I) || isa<SIToFPInst>(I) || isa<UIToFPInst>(I) || isa<FPTruncInst>(I) || isa<FPExtInst>(I))
        work.push_back(&I);
  for (Instruction *I : work) {
    Type *dst = I->getType(), *src = I->getOperand(0)->getType();
    std::string dk = dst->isFPOrFPVectorTy() ? "f" : (isa<FPToUIInst>(I) ? "u" : "s");
    std::string sk = src->isFPOrFPVectorTy() ? "f" : (isa<UIToFPInst>(I) ? "u" : "s");
    bool negBool = src->isIntOrIntVectorTy(1) && isa<SIToFPInst>(I); // signed i1 true is -1
    if (src->isIntOrIntVectorTy(1)) sk = "u";
    std::string name = "air.convert." + dk + "." + airTypeSuffix(dst) + "." + sk + "." + airTypeSuffix(src);
    FunctionCallee fc = M.getOrInsertFunction(name, FunctionType::get(dst, {src}, false));
    if (auto *Fn = dyn_cast<Function>(fc.getCallee())) {
      Fn->addFnAttr(Attribute::NoUnwind);
      Fn->addFnAttr(Attribute::ReadNone);
      Fn->addFnAttr(Attribute::WillReturn);
    }
    IRBuilder<> B(I);
    CallInst *CI = B.CreateCall(fc, {I->getOperand(0)});
    if (isa<FPMathOperator>(CI) && isa<FPMathOperator>(I)) CI->setFastMathFlags(I->getFastMathFlags());
    Value *R = CI;
    if (negBool) R = B.CreateFNeg(CI);
    I->replaceAllUsesWith(R);
    I->eraseFromParent();
  }
}

// Constant samplers: the stdlib passes their 64-bit state as an inttoptr constant; give each state an
// internal constant global and list it in !air.sampler_states, as Apple's compiler does.
static void lowerConstSamplers(Module &M) {
  LLVMContext &C = M.getContext();
  StructType *ST = StructType::getTypeByName(C, "struct._sampler_t");
  if (!ST) return;
  PointerType *SP = PointerType::get(ST, 2);
  std::map<uint64_t, GlobalVariable *> globals;
  std::vector<GlobalVariable *> order;
  for (Function &F : M)
    for (Instruction &I : instructions(F))
      for (Use &U : I.operands()) {
        auto *CE = dyn_cast<ConstantExpr>(U.get());
        if (!CE || CE->getOpcode() != Instruction::IntToPtr || CE->getType() != SP) continue;
        auto *CI = dyn_cast<ConstantInt>(CE->getOperand(0));
        if (!CI) continue;
        uint64_t state = CI->getZExtValue();
        GlobalVariable *&G = globals[state];
        if (!G) {
          G = new GlobalVariable(M, Type::getInt64Ty(C), true, GlobalValue::InternalLinkage,
                                 ConstantInt::get(Type::getInt64Ty(C), state), "__air_sampler_state", nullptr,
                                 GlobalValue::NotThreadLocal, 2);
          G->setAlignment(Align(8));
          order.push_back(G);
        }
        U.set(ConstantExpr::getBitCast(G, SP));
      }
  if (order.empty()) return;
  NamedMDNode *N = M.getOrInsertNamedMetadata("air.sampler_states");
  for (GlobalVariable *G : order)
    N->addOperand(MDNode::get(C, {MDString::get(C, "air.sampler_state"), ConstantAsMetadata::get(G)}));
}


// Remove clang annotations (our attribute carrier). Local variables annotated "air:tg_local" (MSL
// threadgroup variables in function bodies) become internal addrspace(3) globals first.
static StringRef annotationString(Value *V) {
  V = V->stripPointerCasts();
  if (auto *CE = dyn_cast<ConstantExpr>(V)) V = CE->getOperand(0);
  if (auto *G = dyn_cast<GlobalVariable>(V->stripPointerCasts()))
    if (G->hasInitializer())
      if (auto *CDA = dyn_cast<ConstantDataArray>(G->getInitializer()))
        if (CDA->isCString()) return CDA->getAsCString();
  return "";
}

static void stripAnnotations(Module &M) {
  std::vector<CallInst *> calls;
  for (Function &F : M)
    for (Instruction &I : instructions(F))
      if (auto *CI = dyn_cast<CallInst>(&I))
        if (Function *Callee = CI->getCalledFunction())
          if (Callee->getName().startswith("llvm.var.annotation") || Callee->getName().startswith("llvm.ptr.annotation"))
            calls.push_back(CI);
  for (CallInst *CI : calls) {
    Function *Callee = CI->getCalledFunction();
    if (Callee->getName().startswith("llvm.var.annotation") && annotationString(CI->getArgOperand(1)) == "air:tg_local") {
      if (auto *AI = dyn_cast<AllocaInst>(CI->getArgOperand(0)->stripPointerCasts())) {
        Type *T = AI->getAllocatedType();
        auto *G = new GlobalVariable(M, T, false, GlobalValue::InternalLinkage, UndefValue::get(T),
                                     CI->getFunction()->getName() + "." + AI->getName(), nullptr,
                                     GlobalValue::NotThreadLocal, 3);
        G->setAlignment(AI->getAlign());
        CI->eraseFromParent();
        AI->replaceAllUsesWith(ConstantExpr::getAddrSpaceCast(G, AI->getType()));
        AI->eraseFromParent();
        continue;
      }
    }
    if (Callee->getName().startswith("llvm.ptr.annotation")) CI->replaceAllUsesWith(CI->getArgOperand(0));
    CI->eraseFromParent();
  }
  if (GlobalVariable *GA = M.getGlobalVariable("llvm.global.annotations")) GA->eraseFromParent();
}


// Texture reads/samples are declared in the stdlib as "xt.sret.<air name>" returning the texel; AIR returns
// { texel, i8 }. Rewrite the calls.
static void lowerSretIntrinsics(Module &M) {
  std::vector<Function *> decls;
  for (Function &F : M)
    if (F.isDeclaration() && F.getName().startswith("xt.sret.")) decls.push_back(&F);
  for (Function *F : decls) {
    std::string air = F->getName().drop_front(8).str();
    Type *RT = StructType::get(M.getContext(), {F->getReturnType(), Type::getInt8Ty(M.getContext())});
    FunctionType *FT = FunctionType::get(RT, F->getFunctionType()->params(), false);
    FunctionCallee callee = M.getOrInsertFunction(air, FT);
    if (auto *NF = dyn_cast<Function>(callee.getCallee())) {
      NF->addFnAttr(Attribute::NoUnwind);
      NF->addFnAttr(Attribute::ReadOnly);
      NF->addFnAttr(Attribute::WillReturn);
    }
    std::vector<CallInst *> calls;
    for (User *U : F->users()) if (auto *CI = dyn_cast<CallInst>(U)) calls.push_back(CI);
    for (CallInst *CI : calls) {
      IRBuilder<> B(CI);
      std::vector<Value *> args(CI->arg_begin(), CI->arg_end());
      CallInst *NC = B.CreateCall(callee, args);
      Value *V = B.CreateExtractValue(NC, 0);
      CI->replaceAllUsesWith(V);
      CI->eraseFromParent();
    }
    if (F->use_empty()) F->eraseFromParent();
  }
}


// Restore full fast-math flags (and drop OpenCL accuracy metadata) on the final IR.
static void finalizeFPFlags(Module &M, bool fast) {
  for (Function &F : M)
    for (Instruction &I : instructions(F)) {
      I.setMetadata(LLVMContext::MD_fpmath, nullptr);
      if (fast && isa<FPMathOperator>(&I) && !isa<CallInst>(&I) && !isa<PHINode>(&I) && !isa<SelectInst>(&I))
        I.setFast(true);
      if (fast && isa<CallInst>(&I) && isa<FPMathOperator>(&I)) I.setFast(true);
    }
}


// Lifetime markers on non-alloca memory (threadgroup globals) are meaningless; drop them.
static void dropForeignLifetimes(Module &M) {
  std::vector<Instruction *> dead;
  for (Function &F : M)
    for (Instruction &I : instructions(F))
      if (auto *II = dyn_cast<IntrinsicInst>(&I))
        if (II->getIntrinsicID() == Intrinsic::lifetime_start || II->getIntrinsicID() == Intrinsic::lifetime_end)
          if (!isa<AllocaInst>(getUnderlyingObject(II->getArgOperand(1)))) dead.push_back(II);
  for (auto *I : dead) I->eraseFromParent();
}

static void runPasses(Module &M, bool inlineAll) {
  LoopAnalysisManager LAM;
  FunctionAnalysisManager FAM;
  CGSCCAnalysisManager CGAM;
  ModuleAnalysisManager MAM;
  PipelineTuningOptions PTO;
  PTO.LoopVectorization = false;
  PTO.SLPVectorization = false;
  PassBuilder PB(nullptr, PTO);
  PB.registerModuleAnalyses(MAM);
  PB.registerCGSCCAnalyses(CGAM);
  PB.registerFunctionAnalyses(FAM);
  PB.registerLoopAnalyses(LAM);
  PB.crossRegisterProxies(LAM, FAM, CGAM, MAM);
  ModulePassManager MPM;
  if (inlineAll) MPM.addPass(AlwaysInlinerPass());
  MPM.addPass(PB.buildPerModuleDefaultPipeline(OptimizationLevel::O2));
  MPM.addPass(createModuleToFunctionPassAdaptor(InferAddressSpacesPass(4)));
  // Threadgroup variables from function bodies are addrspace(3) globals reached through casts to the private
  // address space; infer their real address space too.
  MPM.addPass(createModuleToFunctionPassAdaptor(InferAddressSpacesPass(0)));
  MPM.addPass(PB.buildPerModuleDefaultPipeline(OptimizationLevel::O1));
  MPM.addPass(GlobalDCEPass());
  MPM.run(M, MAM);
}

struct Versions { int airMaj, airMin, langMaj, langMin; };

static bool parseTriple(const std::string &triple, std::string &os, int &osMaj, int &osMin, bool &sim) {
  // air64-apple-ios15.0-simulator / air64-apple-macosx14.0 / air64-apple-xros1.0-simulator
  SmallVector<StringRef, 4> parts;
  StringRef(triple).split(parts, '-');
  if (parts.size() < 3) return false;
  StringRef o = parts[2];
  size_t i = 0;
  while (i < o.size() && !isdigit(o[i])) ++i;
  os = o.substr(0, i).str();
  StringRef ver = o.substr(i);
  std::pair<StringRef, StringRef> mm = ver.split('.');
  osMaj = 0; osMin = 0;
  mm.first.getAsInteger(10, osMaj);
  StringRef minor = mm.second.split('.').first;
  if (!minor.empty()) minor.getAsInteger(10, osMin);
  sim = parts.size() > 3 && parts[3] == "simulator";
  return true;
}

static Versions versionsFor(const std::string &os, int maj, int min) {
  // MSL version implied by the deployment target (Apple's metal picks the newest the OS supports).
  int lang; // 22 = 2.2 ...
  if (os == "macosx" || os == "macos") {
    if (maj >= 26) lang = 40; else if (maj >= 15) lang = 32; else if (maj >= 14) lang = 31; else if (maj >= 13) lang = 30;
    else if (maj >= 12) lang = 24; else if (maj >= 11) lang = 23; else if (maj == 10 && min >= 15) lang = 22; else lang = 21;
  } else if (os == "xros") {
    if (maj >= 26) lang = 40; else if (maj >= 2) lang = 32; else lang = 31;
  } else if (os == "watchos") {
    if (maj >= 26) lang = 40; else if (maj >= 11) lang = 32; else if (maj >= 10) lang = 31; else if (maj >= 9) lang = 30; else lang = 24;
  } else { // ios, tvos
    if (maj >= 26) lang = 40; else if (maj >= 18) lang = 32; else if (maj >= 17) lang = 31; else if (maj >= 16) lang = 30;
    else if (maj >= 15) lang = 24; else if (maj >= 14) lang = 23; else lang = 22;
  }
  static const std::map<int, std::pair<int, int>> air = {{21, {2, 1}}, {22, {2, 2}}, {23, {2, 3}}, {24, {2, 4}}, {30, {2, 5}},
                                                         {31, {2, 6}}, {32, {2, 7}}, {40, {2, 8}}, {41, {2, 8}}};
  auto a = air.at(lang);
  return {a.first, a.second, lang / 10, lang % 10};
}

static void addModuleMetadata(Module &M, const std::string &airTriple, const Versions &V, bool fastMath,
                              const std::string &source, int sdkMaj, int sdkMin) {
  LLVMContext &C = M.getContext();
  M.setTargetTriple(airTriple);
  M.setDataLayout(kAirDataLayout);
  M.setSourceFileName(source);
  auto i32 = [&](int v) { return ConstantAsMetadata::get(ConstantInt::get(Type::getInt32Ty(C), v)); };
  // Drop clang's spir/OpenCL module metadata.
  for (const char *n : {"opencl.ocl.version", "opencl.spir.version", "opencl.cxx.version", "llvm.ident", "opencl.compiler.options"})
    if (NamedMDNode *N = M.getNamedMetadata(n)) M.eraseNamedMetadata(N);
  if (NamedMDNode *Flags = M.getModuleFlagsMetadata()) M.eraseNamedMetadata(Flags);
  M.addModuleFlag(Module::Warning, "SDK Version",
                  ConstantDataArray::get(C, ArrayRef<uint32_t>({(uint32_t)sdkMaj, (uint32_t)sdkMin})));
  M.addModuleFlag(Module::Error, "wchar_size", 4);
  M.addModuleFlag(Module::Max, "frame-pointer", 2);
  M.addModuleFlag(Module::Max, "air.max_device_buffers", 31);
  M.addModuleFlag(Module::Max, "air.max_constant_buffers", 31);
  M.addModuleFlag(Module::Max, "air.max_threadgroup_buffers", 31);
  M.addModuleFlag(Module::Max, "air.max_textures", 128);
  M.addModuleFlag(Module::Max, "air.max_read_write_textures", 8);
  M.addModuleFlag(Module::Max, "air.max_samplers", 16);
  NamedMDNode *CO = M.getOrInsertNamedMetadata("air.compile_options");
  CO->addOperand(MDNode::get(C, {MDString::get(C, "air.compile.denorms_disable")}));
  CO->addOperand(MDNode::get(C, {MDString::get(C, fastMath ? "air.compile.fast_math_enable" : "air.compile.fast_math_disable")}));
  CO->addOperand(MDNode::get(C, {MDString::get(C, "air.compile.framebuffer_fetch_enable")}));
  M.getOrInsertNamedMetadata("llvm.ident")->addOperand(MDNode::get(C, {MDString::get(C, "xtmetal (clang 15 based)")}));
  M.getOrInsertNamedMetadata("air.version")->addOperand(MDNode::get(C, {i32(V.airMaj), i32(V.airMin), i32(0)}));
  M.getOrInsertNamedMetadata("air.language_version")
      ->addOperand(MDNode::get(C, {MDString::get(C, "Metal"), i32(V.langMaj), i32(V.langMin), i32(0)}));
  M.getOrInsertNamedMetadata("air.source_file_name")->addOperand(MDNode::get(C, {MDString::get(C, source)}));
}

static void cleanupForAir(Module &M) {
  for (Function &F : M) {
    F.setCallingConv(CallingConv::C);
    for (Instruction &I : instructions(F))
      if (auto *CB = dyn_cast<CallBase>(&I)) CB->setCallingConv(CallingConv::C);
    F.removeFnAttr("target-cpu");
    F.removeFnAttr("target-features");
    F.removeFnAttr("uniform-work-group-size");
  }
  // Function constants and other declarations we keep; remove OpenCL kernel arg metadata.
  for (Function &F : M) {
    SmallVector<std::pair<unsigned, MDNode *>, 4> mds;
    F.getAllMetadata(mds);
    for (auto &p : mds) {
      StringRef kind;
      SmallVector<StringRef, 16> names;
      M.getContext().getMDKindNames(names);
      if (p.first < names.size()) kind = names[p.first];
      if (kind.startswith("kernel_arg")) F.setMetadata(p.first, nullptr);
    }
  }
}

static int cmdCompile(int argc, char **argv) {
  std::string input, output, triple = "air64-apple-ios15.0-simulator", source, diag;
  bool fastMath = false;
  int sdkMaj = 26, sdkMin = 5;
  std::vector<std::string> extra;
  for (int i = 2; i < argc; ++i) {
    std::string a = argv[i];
    if (a == "-o") output = argv[++i];
    else if (a == "--triple") triple = argv[++i];
    else if (a == "--source") source = argv[++i];
    else if (a == "--fast-math") fastMath = true;
    else if (a == "--diag") diag = argv[++i];
    else if (a == "--sdk-version") {
      std::string v = argv[++i];
      sdkMaj = atoi(v.c_str());
      auto dot = v.find('.');
      sdkMin = dot == std::string::npos ? 0 : atoi(v.c_str() + dot + 1);
    } else if (a == "--") { for (++i; i < argc; ++i) extra.push_back(argv[i]); }
    else input = a;
  }
  if (input.empty() || output.empty()) die("compile: need input and -o");
  if (source.empty()) source = input;

  std::vector<std::string> args = {"-triple", "spir64-unknown-unknown", "-emit-llvm-only", "-O2", "-disable-llvm-passes",
                                   "-x", "clcpp", "-cl-std=clc++2021", "-cl-ext=+cl_khr_fp16,+cl_khr_fp64,+__opencl_c_fp64,+__opencl_c_generic_address_space,+__opencl_c_program_scope_global_variables,+__opencl_c_images,+__opencl_c_read_write_images,+__opencl_c_atomic_order_seq_cst,+__opencl_c_atomic_scope_device",
                                   "-cl-single-precision-constant", "-cl-fp32-correctly-rounded-divide-sqrt", "-no-opaque-pointers", "-fno-builtin", "-ffreestanding",
                                   "-fno-signed-char", "-Wno-user-defined-literals", "-Wno-unused-value",
                                   "-ferror-limit", "50"};
  if (fastMath) {
    // No -mreassociate: our pipeline must not reassociate (Apple's front end keeps expression order and leaves
    // that to the GPU compiler); full fast-math flags are restored on the final IR.
    for (const char *f : {"-menable-no-infs", "-menable-no-nans", "-fno-signed-zeros", "-freciprocal-math",
                          "-ffp-contract=fast", "-fapprox-func", "-ffinite-math-only", "-D__FAST_MATH__"})
      args.push_back(f);
  } else {
    args.push_back("-ffp-contract=on");
  }
  if (!diag.empty()) { args.push_back("-serialize-diagnostic-file"); args.push_back(diag); }
  for (auto &e : extra) args.push_back(e);
  args.push_back(input);
  std::vector<const char *> cargs;
  for (auto &a : args) cargs.push_back(a.c_str());

  auto CI = std::make_unique<ca::CompilerInstance>();
  IntrusiveRefCntPtr<ca::DiagnosticOptions> DO = new ca::DiagnosticOptions();
  DO->ShowColors = false;
  auto *printer = new ca::TextDiagnosticPrinter(errs(), &*DO);
  CI->createDiagnostics(printer, true);
  if (!ca::CompilerInvocation::CreateFromArgs(CI->getInvocation(), cargs, CI->getDiagnostics())) return 1;
  if (!diag.empty()) CI->getDiagnosticOpts().DiagnosticSerializationFile = diag;
  CI->createDiagnostics(new ca::TextDiagnosticPrinter(errs(), &CI->getDiagnosticOpts()), true);

  LLVMContext Ctx;
  CollectResult R;
  XtAction act(&Ctx, R);
  if (!CI->ExecuteAction(act) || R.error) return 1;
  std::unique_ptr<Module> M = act.takeModule();
  if (!M) return 1;

  std::string os; int osMaj, osMin; bool sim;
  if (!parseTriple(triple, os, osMaj, osMin, sim)) die("bad target triple " + triple);
  Versions V = versionsFor(os, osMaj, osMin);
  std::string airTriple = "air64_v" + std::to_string(V.airMaj) + std::to_string(V.airMin) + "-apple-" + os +
                          std::to_string(osMaj) + "." + std::to_string(osMin) + ".0" + (sim ? "-simulator" : "");

  M->setDataLayout(kAirDataLayout);
  stripAnnotations(*M);
  // Everything but entry points gets inlined; MSL has no recursion or function pointers.
  for (Function &F : *M) {
    if (F.isDeclaration()) continue;
    F.removeFnAttr(Attribute::NoInline);
    F.removeFnAttr(Attribute::OptimizeNone);
    F.addFnAttr(Attribute::AlwaysInline);
  }
  Lowering L(*M, fastMath);
  std::vector<std::pair<EntryDesc *, Function *>> lowered;
  for (auto &E : R.entries) lowered.push_back({&E, L.lowerEntry(E)});
  for (auto &E : R.entries) if (E.stitchable) L.stitchTraits(E);
  // Keep entries and trait helpers alive through GlobalDCE.
  for (Function &F : *M) if (!F.isDeclaration() && !F.hasInternalLinkage() && !F.hasLinkOnceLinkage() && !F.getName().startswith("__xt_user.") && !F.getName().startswith("_ZN5metal22_stitching"))
    if (F.getLinkage() == GlobalValue::ExternalLinkage) {
      bool isEntry = false;
      for (auto &p : lowered) if (p.second == &F) isEntry = true;
      if (!isEntry) F.setLinkage(GlobalValue::InternalLinkage);
    }
  std::vector<Constant *> keep;
  for (auto &E : R.entries) for (auto &st : E.stitchTypes)
    for (const char *suffix : {"13load_argumentEPv", "7destroyEPv", "16copy_from_bufferEPvPU11MTLconstantKv"})
      if (Function *F = M->getFunction(st.first + suffix)) keep.push_back(F);
  for (Function &F : *M) if (F.getName().startswith("_ZN5metal22_stitching") && F.getName().contains("store_return_value")) keep.push_back(&F);
  std::vector<Constant *> keepCasts;
  for (auto *k : keep) keepCasts.push_back(ConstantExpr::getBitCast(k, Type::getInt8PtrTy(Ctx)));
  if (!keepCasts.empty()) {
    auto *AT = ArrayType::get(Type::getInt8PtrTy(Ctx), keepCasts.size());
    auto *G = new GlobalVariable(*M, AT, false, GlobalValue::AppendingLinkage, ConstantArray::get(AT, keepCasts), "llvm.compiler.used");
    G->setSection("llvm.metadata");
  }
  // Function constants: AIR reads them from "<mangled>.MTL_FC_INIT_<index>_<code>" globals.
  for (auto &FC : R.constants) {
    GlobalVariable *G = M->getGlobalVariable(FC.var, true);
    if (!G) continue;
    Type *T = G->getValueType();
    std::string code = FC.typeName == "bool" ? "b" : FC.typeName == "float" ? "f" : FC.typeName == "int" ? "i" :
                       FC.typeName == "uint" ? "j" : FC.typeName == "half" ? "Dh" : FC.typeName == "short" ? "s" :
                       FC.typeName == "ushort" ? "t" : FC.typeName;
    std::string init = FC.var + ".MTL_FC_INIT_" + std::to_string(FC.index) + "_" + code;
    auto *I = new GlobalVariable(*M, T, true, GlobalValue::LinkOnceODRLinkage, UndefValue::get(T), init, nullptr,
                                 GlobalValue::NotThreadLocal, 2, true);
    I->setVisibility(GlobalValue::HiddenVisibility);
    I->setAlignment(G->getAlign() ? *G->getAlign() : Align(4));
    // Reads of the user global become loads of the init global.
    G->replaceAllUsesWith(ConstantExpr::getPointerBitCastOrAddrSpaceCast(I, G->getType()));
    G->eraseFromParent();
  }

  runPasses(*M, true);
  dropForeignLifetimes(*M);
  lowerSretIntrinsics(*M);
  lowerConstSamplers(*M);
  lowerConversions(*M);
  finalizeFPFlags(*M, fastMath);
  cleanupForAir(*M);
  for (GlobalVariable &G : M->globals())
    if (G.getAddressSpace() == 4) die("generic address space global left after lowering: " + G.getName());

  // Entry metadata
  LLVMContext &C = M->getContext();
  std::map<EntryKind, const char *> listName = {{EntryKind::Vertex, "air.vertex"}, {EntryKind::Fragment, "air.fragment"},
                                                {EntryKind::Kernel, "air.kernel"}, {EntryKind::Visible, "air.visible"},
                                                {EntryKind::Mesh, "air.mesh"}, {EntryKind::Object, "air.object"}};
  for (auto &p : lowered) {
    EntryDesc &E = *p.first;
    MD outs = MD::node();
    for (auto &r : E.rets) outs.add(r.md);
    MD ins = MD::node();
    for (auto &a : E.args) for (auto &f : a.fields) ins.add(f.md);
    MD node = MD::node({MD::func(E.name), outs, ins});
    if (E.stitchable) node.add(E.stitching);
    M->getOrInsertNamedMetadata(listName[E.kind])->addOperand(cast<MDNode>(materialize(*M, node)));
  }
  if (!R.constants.empty()) {
    NamedMDNode *N = M->getOrInsertNamedMetadata("air.function_constants");
    for (auto &FC : R.constants) {
      std::string code = FC.typeName == "bool" ? "b" : FC.typeName == "float" ? "f" : FC.typeName == "int" ? "i" :
                         FC.typeName == "uint" ? "j" : FC.typeName == "half" ? "Dh" : FC.typeName == "short" ? "s" :
                         FC.typeName == "ushort" ? "t" : FC.typeName;
      GlobalVariable *I = M->getGlobalVariable(FC.var + ".MTL_FC_INIT_" + std::to_string(FC.index) + "_" + code, true);
      if (!I) continue;
      N->addOperand(MDNode::get(C, {ConstantAsMetadata::get(I), MDString::get(C, FC.typeName), MDString::get(C, FC.name),
                                    ConstantAsMetadata::get(ConstantInt::get(Type::getInt32Ty(C), FC.index))}));
    }
  }
  addModuleMetadata(*M, airTriple, V, fastMath, source, sdkMaj, sdkMin);
  if (verifyModule(*M, &errs())) die("internal: generated module does not verify");

  std::error_code EC;
  raw_fd_ostream out(output, EC, sys::fs::OF_None);
  if (EC) die("cannot write " + output + ": " + EC.message());
  WriteBitcodeToFile(*M, out);
  return 0;
}

// ---------------------------------------------------------------------------------------------------------------
// Linking: one bitcode module per function in a metallib container.

static void put16(std::string &s, uint16_t v) { s.append((const char *)&v, 2); }
static void put32(std::string &s, uint32_t v) { s.append((const char *)&v, 4); }
static void put64(std::string &s, uint64_t v) { s.append((const char *)&v, 8); }
static void tag(std::string &s, const char *name, const std::string &payload) {
  s.append(name, 4);
  put16(s, payload.size());
  s += payload;
}

static int cmdLink(int argc, char **argv) {
  std::string output;
  std::vector<std::string> inputs;
  for (int i = 2; i < argc; ++i) {
    std::string a = argv[i];
    if (a == "-o") output = argv[++i];
    else inputs.push_back(a);
  }
  if (output.empty() || inputs.empty()) die("link: need -o and inputs");
  LLVMContext C;
  std::unique_ptr<Module> All;
  for (auto &in : inputs) {
    auto buf = MemoryBuffer::getFile(in);
    if (!buf) die("cannot read " + in);
    auto Mod = parseBitcodeFile((*buf)->getMemBufferRef(), C);
    if (!Mod) die("cannot parse " + in + ": " + toString(Mod.takeError()));
    if (!All) { All = std::move(*Mod); continue; }
    // Keep named metadata lists from both (Linker appends named metadata).
    if (Linker::linkModules(*All, std::move(*Mod))) die("link failed for " + in);
  }
  // Deduplicate per-module singletons that the linker concatenated.
  for (const char *n : {"air.version", "air.language_version", "air.compile_options", "llvm.ident", "air.source_file_name"}) {
    NamedMDNode *N = All->getNamedMetadata(n);
    if (!N) continue;
    std::vector<MDNode *> uniq;
    for (MDNode *op : N->operands()) if (std::find(uniq.begin(), uniq.end(), op) == uniq.end()) uniq.push_back(op);
    N->clearOperands();
    for (auto *op : uniq) N->addOperand(op);
  }
  struct Fn { std::string name; int type; std::string bc; };
  std::vector<Fn> fns;
  std::vector<std::pair<const char *, int>> lists = {{"air.vertex", 0}, {"air.fragment", 1}, {"air.kernel", 2}, {"air.visible", 4},
                                                     {"air.mesh", 7}, {"air.object", 8}};
  // Collect entries in module function order.
  std::map<Function *, std::pair<const char *, int>> entryKind;
  std::map<Function *, MDNode *> entryNode;
  for (auto &l : lists) {
    NamedMDNode *N = All->getNamedMetadata(l.first);
    if (!N) continue;
    for (MDNode *op : N->operands()) {
      auto *F = mdconst::dyn_extract_or_null<Function>(op->getOperand(0));
      if (!F) continue;
      entryKind[F] = l;
      entryNode[F] = op;
    }
  }
  Triple TT(All->getTargetTriple());
  int airMaj = 2, airMin = 4, langMaj = 2, langMin = 4;
  if (NamedMDNode *N = All->getNamedMetadata("air.version"))
    if (N->getNumOperands()) {
      airMaj = mdconst::extract<ConstantInt>(N->getOperand(0)->getOperand(0))->getZExtValue();
      airMin = mdconst::extract<ConstantInt>(N->getOperand(0)->getOperand(1))->getZExtValue();
    }
  if (NamedMDNode *N = All->getNamedMetadata("air.language_version"))
    if (N->getNumOperands()) {
      langMaj = mdconst::extract<ConstantInt>(N->getOperand(0)->getOperand(1))->getZExtValue();
      langMin = mdconst::extract<ConstantInt>(N->getOperand(0)->getOperand(2))->getZExtValue();
    }
  for (Function &F : *All) {
    if (!entryKind.count(&F)) continue;
    ValueToValueMapTy VM;
    std::unique_ptr<Module> Clone = CloneModule(*All, VM);
    Function *CF = cast<Function>(VM[&F]);
    // Keep only this entry in the entry lists.
    for (auto &l : lists) {
      NamedMDNode *N = Clone->getNamedMetadata(l.first);
      if (!N) continue;
      std::vector<MDNode *> keepOps;
      for (MDNode *op : N->operands()) {
        auto *EF = mdconst::dyn_extract_or_null<Function>(op->getOperand(0));
        if (EF == CF) keepOps.push_back(op);
      }
      N->clearOperands();
      if (keepOps.empty()) Clone->eraseNamedMetadata(N);
      else for (auto *op : keepOps) N->addOperand(op);
    }
    // Other entries become unreachable.
    for (Function &G : *Clone) {
      if (&G == CF || G.isDeclaration()) continue;
      if (G.getName().startswith("_ZN5metal22_stitching")) continue;
      G.setLinkage(GlobalValue::InternalLinkage);
    }
    // Keep only the compiler.used entries (stitching trait helpers) that this entry's metadata references.
    if (GlobalVariable *U = Clone->getGlobalVariable("llvm.compiler.used")) {
      std::set<Function *> referenced;
      std::function<void(const MDNode *)> scan = [&](const MDNode *N) {
        for (const MDOperand &O : N->operands()) {
          if (!O) continue;
          if (auto *VM = dyn_cast<ValueAsMetadata>(O.get()))
            if (auto *RF = dyn_cast<Function>(VM->getValue()->stripPointerCasts())) referenced.insert(RF);
          if (auto *Sub = dyn_cast<MDNode>(O.get())) scan(Sub);
        }
      };
      for (auto &l : lists)
        if (NamedMDNode *N = Clone->getNamedMetadata(l.first))
          for (MDNode *op : N->operands()) scan(op);
      std::vector<Constant *> keepUsed;
      if (auto *CA = dyn_cast<ConstantArray>(U->getInitializer()))
        for (Value *Op : CA->operands())
          if (auto *RF = dyn_cast<Function>(Op->stripPointerCasts()))
            if (referenced.count(RF)) keepUsed.push_back(cast<Constant>(Op));
      U->eraseFromParent();
      if (!keepUsed.empty()) {
        auto *AT = ArrayType::get(Type::getInt8PtrTy(C), keepUsed.size());
        auto *G = new GlobalVariable(*Clone, AT, false, GlobalValue::AppendingLinkage, ConstantArray::get(AT, keepUsed), "llvm.compiler.used");
        G->setSection("llvm.metadata");
      }
    }
    {
      ModuleAnalysisManager MAM;
      PassBuilder PB;
      PB.registerModuleAnalyses(MAM);
      ModulePassManager MPM;
      MPM.addPass(GlobalDCEPass());
      MPM.run(*Clone, MAM);
    }
    // Drop sampler states and function constants that no longer exist.
    for (const char *n : {"air.sampler_states", "air.function_constants"}) {
      NamedMDNode *N = Clone->getNamedMetadata(n);
      if (!N) continue;
      std::vector<MDNode *> keepOps;
      for (MDNode *op : N->operands()) {
        bool ok = true;
        for (auto &o : op->operands()) if (!o) ok = false;
        if (ok) keepOps.push_back(op);
      }
      N->clearOperands();
      if (keepOps.empty()) Clone->eraseNamedMetadata(N);
      else for (auto *op : keepOps) N->addOperand(op);
    }
    std::string bc;
    raw_string_ostream os(bc);
    WriteBitcodeToFile(*Clone, os);
    os.flush();
    fns.push_back({F.getName().str(), entryKind[&F].second, bc});
  }

  // Container
  std::string os = TT.getOSName().str();
  std::string flist, pub, priv, bcs;
  for (auto &f : fns) {
    std::string body;
    tag(body, "NAME", f.name + std::string(1, '\0'));
    tag(body, "TYPE", std::string(1, (char)f.type));
    std::array<uint8_t, 32> h = SHA256::hash(ArrayRef<uint8_t>((const uint8_t *)f.bc.data(), f.bc.size()));
    tag(body, "HASH", std::string((const char *)h.data(), 32));
    std::string offt;
    put64(offt, pub.size()); put64(offt, priv.size()); put64(offt, bcs.size());
    tag(body, "OFFT", offt);
    std::string vers;
    put16(vers, airMaj); put16(vers, airMin); put16(vers, langMaj); put16(vers, langMin);
    tag(body, "VERS", vers);
    std::string mdsz;
    put64(mdsz, f.bc.size());
    tag(body, "MDSZ", mdsz);
    body += "ENDT";
    put32(flist, body.size() + 4);
    flist += body;
    put32(pub, 8); pub += "ENDT";
    put32(priv, 8); priv += "ENDT";
    bcs += f.bc;
  }
  std::array<uint8_t, 32> uh = SHA256::hash(ArrayRef<uint8_t>((const uint8_t *)bcs.data(), bcs.size()));
  std::string ext;
  tag(ext, "UUID", std::string((const char *)uh.data(), 16));
  ext += "ENDT";

  // Header fields
  bool isMac = TT.isMacOSX() || os.rfind("macos", 0) == 0;
  uint16_t platform = isMac ? 0x8001 : 0x0001;
  VersionTuple osv = TT.getOSVersion();
  unsigned osMaj = osv.getMajor(), osMin = osv.getMinor().value_or(0);
  bool sim = TT.getEnvironmentName() == "simulator" || StringRef(All->getTargetTriple()).endswith("-simulator");
  uint8_t osId = 0;
  StringRef osName = TT.getOSName();
  if (osName.startswith("macos")) osId = 0x81;
  else if (osName.startswith("ios")) osId = sim ? 0x87 : 0x82;
  else if (osName.startswith("tvos")) osId = sim ? 0x88 : 0x83;
  else if (osName.startswith("watchos")) osId = sim ? 0x89 : 0x84;
  else if (osName.startswith("xros")) osId = sim ? 0x8c : 0x8b;
  // File format minor version by AIR version (observed from Apple's metallib).
  int fileMinor = airMin <= 3 ? 5 : airMin == 4 ? 6 : airMin <= 6 ? 7 : airMin == 7 ? 8 : 9;
  if (airMin <= 3) { osId = 0; osMaj = osMin = 0; }

  std::string data;
  uint64_t flOff = 0x58;
  uint64_t pubOff = flOff + 4 + flist.size() + ext.size();
  uint64_t privOff = pubOff + pub.size();
  uint64_t bcOff = privOff + priv.size();
  uint64_t total = bcOff + bcs.size();
  data += "MTLB";
  put16(data, platform);
  put16(data, 2); put16(data, fileMinor);
  data += (char)0;
  data += (char)osId;
  put16(data, osMaj); put16(data, osMin);
  put64(data, total);
  put64(data, flOff); put64(data, flist.size());
  put64(data, pubOff); put64(data, pub.size());
  put64(data, privOff); put64(data, priv.size());
  put64(data, bcOff); put64(data, bcs.size());
  put32(data, fns.size());
  data += flist + ext + pub + priv + bcs;
  if (data.size() != total) die("internal: metallib size mismatch");
  std::error_code EC;
  raw_fd_ostream out(output, EC, sys::fs::OF_None);
  if (EC) die("cannot write " + output);
  out << data;
  return 0;
}

int main(int argc, char **argv) {
  if (argc < 2) die("usage: xtmetal compile|link ...");
  std::string cmd = argv[1];
  if (cmd == "compile") return cmdCompile(argc, argv);
  if (cmd == "link") return cmdLink(argc, argv);
  die("unknown command " + cmd);
}
