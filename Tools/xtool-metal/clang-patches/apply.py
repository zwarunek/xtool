#!/usr/bin/env python3
"""Patch clang 15 for Metal Shading Language semantics, enabled at runtime by clang::XtMSL (set by xtmetal).

- vector op scalar: convert the scalar to the element type (OpenCL rejects higher-rank scalars)
- vector comparisons and logical ops produce `bool` vectors (signed char elements) holding 0/1
- T(args) / T{args} for ext vector types T calls __xt_make<T>(args) (MSL vector construction)
"""
import sys, os
root = sys.argv[1]

def patch(path, old, new, count=1):
    p = os.path.join(root, path)
    s = open(p).read()
    if new in s:
        return
    if s.count(old) < count:
        sys.exit(f'patch target not found in {path}: {old[:60]!r}')
    s = s.replace(old, new, count)
    open(p, 'w').write(s)

DECL = 'namespace clang { extern bool XtMSL; }\n'
patch('clang/lib/Sema/Sema.cpp', '#include "UsedDeclVisitor.h"\n',
      '#include "UsedDeclVisitor.h"\nnamespace clang { bool XtMSL = false; }\n')
patch('clang/lib/Sema/SemaExpr.cpp', '#include "TreeTransform.h"\n', '#include "TreeTransform.h"\n' + DECL)
patch('clang/lib/Sema/SemaExprCXX.cpp', '#include "TreeTransform.h"\n', '#include "TreeTransform.h"\n' + DECL)
patch('clang/lib/CodeGen/CGExprScalar.cpp', '#include "CGCXXABI.h"\n', '#include "CGCXXABI.h"\n' + DECL)

# A: scalar rank rule
patch('clang/lib/Sema/SemaExpr.cpp',
      '    if (S.getLangOpts().OpenCL && (scalarTy->isRealFloatingType() ||',
      '    if (S.getLangOpts().OpenCL && !XtMSL && (scalarTy->isRealFloatingType() ||')
patch('clang/lib/Sema/SemaExpr.cpp',
      '''    if (!scalarTy->isIntegralType(S.Context))
      return true;
    scalarCast = CK_IntegralCast;''',
      '''    if (XtMSL && scalarTy->isRealFloatingType())
      scalarCast = CK_FloatingToIntegral;
    else if (!scalarTy->isIntegralType(S.Context))
      return true;
    else
      scalarCast = CK_IntegralCast;''')
patch('clang/lib/Sema/SemaExpr.cpp',
      '''      if (S.getLangOpts().OpenCL &&
          S.Context.getFloatingTypeOrder(vectorEltTy, scalarTy) < 0) {''',
      '''      if (S.getLangOpts().OpenCL && !XtMSL &&
          S.Context.getFloatingTypeOrder(vectorEltTy, scalarTy) < 0) {''')
# B: comparison result type
patch('clang/lib/Sema/SemaExpr.cpp',
      '''  unsigned TypeSize = Context.getTypeSize(VTy->getElementType());

  if (isa<ExtVectorType>(VTy)) {''',
      '''  unsigned TypeSize = Context.getTypeSize(VTy->getElementType());

  if (XtMSL && isa<ExtVectorType>(VTy))
    return Context.getExtVectorType(Context.SignedCharTy, VTy->getNumElements());
  if (isa<ExtVectorType>(VTy)) {''')
# C: 0/1 instead of 0/-1
for _ in range(4):
    pass
p = os.path.join(root, 'clang/lib/CodeGen/CGExprScalar.cpp')
s = open(p).read()
for var in ('Result', 'And', 'Or'):
    s = s.replace(f'Builder.CreateSExt({var}, ConvertType(E->getType()), "sext")',
                  f'(XtMSL ? Builder.CreateZExt({var}, ConvertType(E->getType()), "zext") : Builder.CreateSExt({var}, ConvertType(E->getType()), "sext"))')
open(p, 'w').write(s)
# D: vector construction
patch('clang/lib/Sema/SemaExprCXX.cpp',
      '''  QualType Ty = TInfo->getType();
  SourceLocation TyBeginLoc = TInfo->getTypeLoc().getBeginLoc();

  assert((!ListInitialization ||''',
      '''  QualType Ty = TInfo->getType();
  SourceLocation TyBeginLoc = TInfo->getTypeLoc().getBeginLoc();

  if (XtMSL && !Ty->isDependentType() && Ty->isExtVectorType()) {
    LookupResult R(*this, &Context.Idents.get("__xt_make"), TyBeginLoc, LookupOrdinaryName);
    if (LookupQualifiedName(R, Context.getTranslationUnitDecl()) && !R.empty()) {
      SmallVector<Expr *, 8> Args;
      if (ListInitialization) {
        auto *IL = cast<InitListExpr>(Exprs[0]);
        Args.append(IL->inits().begin(), IL->inits().end());
      } else {
        Args.append(Exprs.begin(), Exprs.end());
      }
      TemplateArgumentListInfo TAL(LParenOrBraceLoc, RParenOrBraceLoc);
      TAL.addArgument(TemplateArgumentLoc(TemplateArgument(Ty), TInfo));
      CXXScopeSpec SS;
      ExprResult Fn = BuildTemplateIdExpr(SS, SourceLocation(), R, /*RequiresADL=*/false, &TAL);
      if (Fn.isInvalid())
        return ExprError();
      return BuildCallExpr(nullptr, Fn.get(), LParenOrBraceLoc, Args, RParenOrBraceLoc);
    }
  }

  assert((!ListInitialization ||''')
# E: C-style casts to vector types convert elementwise (MSL), like the functional form
patch('clang/lib/Sema/SemaCast.cpp', '#include "clang/AST/ASTContext.h"\n', '#include "clang/AST/ASTContext.h"\n' + DECL)
patch('clang/lib/Sema/SemaCast.cpp',
      '''                                     Expr *CastExpr) {
  CastOperation Op(*this, CastTypeInfo->getType(), CastExpr);''',
      '''                                     Expr *CastExpr) {
  if (XtMSL && CastTypeInfo->getType()->isExtVectorType() && !CastTypeInfo->getType()->isDependentType() &&
      !CastExpr->isTypeDependent() && !isa<InitListExpr>(CastExpr) && !isa<ParenListExpr>(CastExpr)) {
    QualType From = CastExpr->getType();
    const auto *FV = From->getAs<ExtVectorType>();
    const auto *TV = CastTypeInfo->getType()->getAs<ExtVectorType>();
    if ((FV && FV->getNumElements() == TV->getNumElements() &&
         !Context.hasSameUnqualifiedType(FV->getElementType(), TV->getElementType())) ||
        From->isArithmeticType())
      return BuildCXXTypeConstructExpr(CastTypeInfo, LPLoc, MultiExprArg(&CastExpr, 1), RPLoc, false);
  }
  CastOperation Op(*this, CastTypeInfo->getType(), CastExpr);''')
print('patched')
