/* tlpm_mini.h — Minimal TLPM declarations for MATLAB R2019b loadlibrary.
   The full TLPM.h uses __fastcall__ / __attribute__ decorators that crash
   MATLAB's prototype parser. This file declares only the 6 functions used
   by tfp.calibration.powerMeterSweep, using plain C types throughout.
   Function signatures are taken from TLPM.h (IVI Foundation, 2019-12-12).
*/

typedef unsigned int    ViUInt32;
typedef int             ViInt32;
typedef ViInt32         ViStatus;
typedef ViUInt32        ViSession;
typedef ViUInt32*       ViPSession;
typedef double          ViReal64;
typedef double*         ViPReal64;
typedef unsigned short  ViBoolean;
typedef char            ViChar;
typedef char*           ViRsrc;

ViStatus TLPM_findRsrc    (ViSession vi, ViUInt32* resourceCount);
ViStatus TLPM_getRsrcName (ViSession vi, ViUInt32 index, ViChar* resourceName);
ViStatus TLPM_init        (ViRsrc resourceName, ViBoolean IDQuery, ViBoolean resetDevice, ViPSession vi);
ViStatus TLPM_close       (ViSession vi);
ViStatus TLPM_setWavelength(ViSession vi, ViReal64 wavelength);
ViStatus TLPM_measPower   (ViSession vi, ViPReal64 power);
