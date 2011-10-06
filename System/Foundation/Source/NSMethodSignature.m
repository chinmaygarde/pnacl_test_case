/** Implementation of NSMethodSignature for GNUStep
   Copyright (C) 1994, 1995, 1996, 1998 Free Software Foundation, Inc.

   Written by:  Andrew Kachites McCallum <mccallum@gnu.ai.mit.edu>
   Date: August 1994
   Rewritten:   Richard Frith-Macdonald <richard@brainstorm.co.uk>
   Date: August 1998

   This file is part of the GNUstep Base Library.

   This library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Lesser General Public
   License as published by the Free Software Foundation; either
   version 2 of the License, or (at your option) any later version.

   This library is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   Library General Public License for more details.

   You should have received a copy of the GNU Lesser General Public
   License along with this library; if not, write to the Free
   Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
   Boston, MA 02111 USA.

   <title>NSMethodSignature class reference</title>
   $Date: 2010-09-09 08:06:09 -0700 (Thu, 09 Sep 2010) $ $Revision: 31265 $
   */

#import "common.h"
#include <objc/encoding.h>
#define	EXPOSE_NSMethodSignature_IVARS	1

#import "Foundation/NSMethodSignature.h"
#import "Foundation/NSException.h"
#import "Foundation/NSCoder.h"

#import "GSInvocation.h"

#ifdef HAVE_MALLOC_H
#include <malloc.h>
#endif
#ifdef HAVE_ALLOCA_H
#include <alloca.h>
#endif

#undef alloca

/* The objc runtime library objc_skip_offset() is buggy on some compiler
 * versions, so we use our own alternative implementation.
 */
static const char *
skip_offset(const char *ptr)
{
  if (*ptr == '+' || *ptr == '-') ptr++;
  while (isdigit(*ptr)) ptr++;
  return ptr;
}

#define ROUND(V, A) \
  ({ typeof(V) __v=(V); typeof(A) __a=(A); \
     __a*((__v+__a-1)/__a); })

/* Step through method encoding information extracting details.
 * If outTypes is non-nul then we copy the qualified type into
 * the buffer as a nul terminated string and use the values in
 * this buffer for the qtype and type in info, rather than pointers
 * to positions in typePtr
 */
static const char *
next_arg(const char *typePtr, NSArgumentInfo *info, char *outTypes)
{
  NSArgumentInfo	local;
  BOOL			flag;
  BOOL			negative = NO;

  if (info == 0)
    {
      info = &local;
    }

  info->qtype = typePtr;

  /*
   *	Skip past any type qualifiers - if the caller wants them, return them.
   */
  flag = YES;
  info->qual = 0;
  while (flag)
    {
      switch (*typePtr)
	{
	  case _C_CONST:  info->qual |= _F_CONST; break;
	  case _C_IN:     info->qual |= _F_IN; break;
	  case _C_INOUT:  info->qual |= _F_INOUT; break;
	  case _C_OUT:    info->qual |= _F_OUT; break;
	  case _C_BYCOPY: info->qual |= _F_BYCOPY; break;
#ifdef	_C_BYREF
	  case _C_BYREF:  info->qual |= _F_BYREF; break;
#endif
	  case _C_ONEWAY: info->qual |= _F_ONEWAY; break;
#ifdef	_C_GCINVISIBLE
	  case _C_GCINVISIBLE:  info->qual |= _F_GCINVISIBLE; break;
#endif
	  default: flag = NO;
	}
      if (flag)
	{
	  typePtr++;
	}
    }

  info->type = typePtr;

  /*
   *	Scan for size and alignment information.
   */
  switch (*typePtr++)
    {
      case _C_ID:
	info->size = sizeof(id);
	info->align = __alignof__(id);
	break;

      case _C_CLASS:
	info->size = sizeof(Class);
	info->align = __alignof__(Class);
	break;

      case _C_SEL:
	info->size = sizeof(SEL);
	info->align = __alignof__(SEL);
	break;

      case _C_CHR:
	info->size = sizeof(char);
	info->align = __alignof__(char);
	break;

      case _C_UCHR:
	info->size = sizeof(unsigned char);
	info->align = __alignof__(unsigned char);
	break;

      case _C_SHT:
	info->size = sizeof(short);
	info->align = __alignof__(short);
	break;

      case _C_USHT:
	info->size = sizeof(unsigned short);
	info->align = __alignof__(unsigned short);
	break;

      case _C_INT:
	info->size = sizeof(int);
	info->align = __alignof__(int);
	break;

      case _C_UINT:
	info->size = sizeof(unsigned int);
	info->align = __alignof__(unsigned int);
	break;

      case _C_LNG:
	info->size = sizeof(long);
	info->align = __alignof__(long);
	break;

      case _C_ULNG:
	info->size = sizeof(unsigned long);
	info->align = __alignof__(unsigned long);
	break;

      case _C_LNG_LNG:
	info->size = sizeof(long long);
	info->align = __alignof__(long long);
	break;

      case _C_ULNG_LNG:
	info->size = sizeof(unsigned long long);
	info->align = __alignof__(unsigned long long);
	break;

      case _C_FLT:
	info->size = sizeof(float);
	info->align = __alignof__(float);
	break;

      case _C_DBL:
	info->size = sizeof(double);
	info->align = __alignof__(double);
	break;

      case _C_PTR:
	info->size = sizeof(char*);
	info->align = __alignof__(char*);
	if (*typePtr == '?')
	  {
	    typePtr++;
	  }
	else
	  {
	    typePtr = objc_skip_typespec(typePtr);
	  }
	break;

      case _C_ATOM:
      case _C_CHARPTR:
	info->size = sizeof(char*);
	info->align = __alignof__(char*);
	break;

      case _C_ARY_B:
	{
	  int	length = atoi(typePtr);

	  while (isdigit(*typePtr))
	    {
	      typePtr++;
	    }
	  typePtr = next_arg(typePtr, &local, 0);
	  info->size = length * ROUND(local.size, local.align);
	  info->align = local.align;
	  typePtr++;	/* Skip end-of-array	*/
	}
	break;

      case _C_STRUCT_B:
	{
	  unsigned int acc_size = 0;
	  unsigned int def_align = objc_alignof_type(typePtr-1);
	  unsigned int acc_align = def_align;
	  const char	*ptr = typePtr;

	  /*
	   *	Skip "<name>=" stuff.
	   */
	  while (*ptr != _C_STRUCT_E && *ptr != '=') ptr++;
	  if (*ptr == '=') typePtr = ptr;
	  typePtr++;

	  /*
	   *	Base structure alignment on first element.
	   */
	  if (*typePtr != _C_STRUCT_E)
	    {
	      typePtr = next_arg(typePtr, &local, 0);
	      if (typePtr == 0)
		{
		  return 0;		/* error	*/
		}
	      acc_size = ROUND(acc_size, local.align);
	      acc_size += local.size;
	      acc_align = MAX(local.align, def_align);
	    }
	  /*
	   *	Continue accumulating structure size
	   *	and adjust alignment if necessary
	   */
	  while (*typePtr != _C_STRUCT_E)
	    {
	      typePtr = next_arg(typePtr, &local, 0);
	      if (typePtr == 0)
		{
		  return 0;		/* error	*/
		}
	      acc_size = ROUND(acc_size, local.align);
	      acc_size += local.size;
	      acc_align = MAX(local.align, acc_align);
	    }
	  /*
	   * Size must be a multiple of alignment
	   */
	  if (acc_size % acc_align != 0)
	    {
	      acc_size += acc_align - acc_size % acc_align;
	    }
	  info->size = acc_size;
	  info->align = acc_align;
	  typePtr++;	/* Skip end-of-struct	*/
	}
	break;

      case _C_UNION_B:
	{
	  unsigned int	max_size = 0;
	  unsigned int	max_align = 0;

	  /*
	   *	Skip "<name>=" stuff.
	   */
	  while (*typePtr != _C_UNION_E)
	    {
	      if (*typePtr++ == '=')
		{
		  break;
		}
	    }
	  while (*typePtr != _C_UNION_E)
	    {
	      typePtr = next_arg(typePtr, &local, 0);
	      if (typePtr == 0)
		{
		  return 0;		/* error	*/
		}
	      max_size = MAX(max_size, local.size);
	      max_align = MAX(max_align, local.align);
	    }
	  info->size = max_size;
	  info->align = max_align;
	  typePtr++;	/* Skip end-of-union	*/
	}
	break;

      case _C_VOID:
	info->size = 0;
	info->align = __alignof__(char*);
	break;

      default:
	return 0;
    }

  if (typePtr == 0)
    {		/* Error condition.	*/
      return 0;
    }

  /* Copy the type information into the buffer if provided.
   */
  if (outTypes != 0)
    {
      unsigned	len = typePtr - info->qtype;

      strncpy(outTypes, info->qtype, len);
      outTypes[len] = '\0';
      info->qtype = outTypes;
      info->type = objc_skip_type_qualifiers (outTypes);
    }

  /*
   *	May tell the caller if the item is stored in a register.
   */
  if (*typePtr == '+')
    {
      typePtr++;
      info->isReg = YES;
    }
  else
    {
      info->isReg = NO;
    }
  /*
   * Cope with negative offsets.
   */
  if (*typePtr == '-')
    {
      typePtr++;
      negative = YES;
    }
  /*
   *	May tell the caller what the stack/register offset is for
   *	this argument.
   */
  info->offset = 0;
  while (isdigit(*typePtr))
    {
      info->offset = info->offset * 10 + (*typePtr++ - '0');
    }
  if (negative == YES)
    {
      info->offset = -info->offset;
    }

  return typePtr;
}

@implementation NSMethodSignature

- (id) _initWithObjCTypes: (const char*)t
{
  const char	*p = t;
  
  if (t == 0 || *t == '\0')
    {
      DESTROY(self);
    }
  else
    {
      const char	*q;
      char		*args;
      char		*ret;

/* In case we have been given a method encoding string without offsets,
 * we attempt to generate the frame size and offsets in a new copy of
 * the types string.
 */
      ret = alloca((strlen(t)+1)*16);

      /* Copy the return type (including qualifiers) with ehough room
       * after it to store the frame size.
       */
      p = t;
      p = objc_skip_typespec (p);
      strncpy(ret, t, p - t);
      ret[p - t] = '\0';
      args = ret + (p - t) + 10;
      *args = '\0';

      /* Skip to the first arg type, taking note of where the qualifiers start.
       * Assume that casting _argFrameLength to int will not lose information.
       */
      p = skip_offset (p);
      q = p;
      p = objc_skip_type_qualifiers (p);
      while (p && *p)
	{
	  int	size;

	  _numArgs++;
	  size = objc_promoted_size (p);
	  p = objc_skip_typespec (p);
	  strncat(args, q, p - q);
	  sprintf(args + strlen(args), "%d", (int)_argFrameLength);
	  _argFrameLength += size;
	  p = skip_offset (p);
	  q = p;
	  p = objc_skip_type_qualifiers (p);
	}
      sprintf(ret + strlen(ret), "%d", (int)_argFrameLength);
      _methodTypes = NSZoneMalloc(NSDefaultMallocZone(),
	strlen(args) + strlen(ret) + 1);
      strcpy((char*)_methodTypes, ret);
      strcat((char*)_methodTypes, args);
    }
  return self;
}

+ (NSMethodSignature*) signatureWithObjCTypes: (const char*)t
{
  return AUTORELEASE([[[self class] alloc] _initWithObjCTypes: t]);
}

- (NSArgumentInfo) argumentInfoAtIndex: (NSUInteger)index
{
  if (index >= _numArgs)
    {
      [NSException raise: NSInvalidArgumentException
		  format: @"Index too high."];
    }
  if (_inf == 0)
    {
      [self methodInfo];
    }
  return _inf[index+1];
}

- (NSUInteger) frameLength
{
  return _argFrameLength;
}

- (const char*) getArgumentTypeAtIndex: (NSUInteger)index
{
  if (index >= _numArgs)
    {
      [NSException raise: NSInvalidArgumentException
		  format: @"Index too high."];
    }
  if (_inf == 0)
    {
      [self methodInfo];
    }
  return _inf[index+1].qtype;
}

- (BOOL) isOneway
{
  if (_inf == 0)
    {
      [self methodInfo];
    }
  return (_inf[0].qual & _F_ONEWAY) ? YES : NO;
}

- (NSUInteger) methodReturnLength
{
  if (_inf == 0)
    {
      [self methodInfo];
    }
  return _inf[0].size;
}

- (const char*) methodReturnType
{
  if (_inf == 0)
    {
      [self methodInfo];
    }
  return _inf[0].qtype;
}

- (NSUInteger) numberOfArguments
{
  return _numArgs;
}

- (void) dealloc
{
  if (_methodTypes)
    NSZoneFree(NSDefaultMallocZone(), (void*)_methodTypes);
  if (_inf)
    NSZoneFree(NSDefaultMallocZone(), (void*)_inf);
  [super dealloc];
}

- (BOOL) isEqual: (id)other
{
  BOOL isEqual = YES;
  if (other == nil)
    {
      return NO;
    }
  if (((NSMethodSignature *)other)->isa != isa)
    {
      return NO;
    }
  isEqual = ([self numberOfArguments] == [other numberOfArguments]
    && [self frameLength] == [other frameLength]
    && *[self methodReturnType] == *[other methodReturnType]
    && [self isOneway] == [other isOneway]);
  if (isEqual == NO)
    {
      return NO;
    }
  else
    {
      int i, n;
      n = [self numberOfArguments];
      for (i = 0; i < n; i++)
        {
          if ((*[self getArgumentTypeAtIndex:i]
		== *[other getArgumentTypeAtIndex:i]) == NO)
            {
              return NO;
            }
        }
    }
  return isEqual;
}

@end

@implementation NSMethodSignature(GNUstep)
- (NSArgumentInfo*) methodInfo
{
  if (_inf == 0)
    {
      const char	*types = _methodTypes;
      char		*outTypes;
      unsigned int	i;

      /* Allocate space enough for an NSArgumentInfo structure for each
       * argument (including the return type), and enough space to hold
       * the type information for each argument as a nul terminated
       * string.
       */
      outTypes = NSZoneMalloc(NSDefaultMallocZone(),
	sizeof(NSArgumentInfo)*(_numArgs+1) + strlen(types)*2);
      _info = (void*)outTypes;
      outTypes = outTypes + sizeof(NSArgumentInfo)*(_numArgs+1);
      /* Fill in the full argment information for each arg.
       */
      for (i = 0; i <= _numArgs; i++)
	{
	  types = next_arg(types, &_inf[i], outTypes);
	  outTypes += strlen(outTypes) + 1;
	}
    }
  return _inf;
}

- (const char*) methodType
{
  return _methodTypes;
}
@end
