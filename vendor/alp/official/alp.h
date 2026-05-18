
/***********************************************************************************/
/**                                                                               **/
/**   Project:      alp   (ALP DLL)                                               **/
/**   Filename:     alp.h : Header File                                           **/
/**                                                                               **/
/***********************************************************************************/
/**                                                                               **/
/**   © 2004-2024 ViALUX GmbH. All rights reserved.                               **/
/**                                                                               **/
/***********************************************************************************/
/**                                                                               **/
/**   Version:        28                                                          **/
/**                                                                               **/
/***********************************************************************************/


#ifndef _ALP_H_INCLUDED
#define _ALP_H_INCLUDED


#ifndef ALP_API

#define ALP_ATTR

#ifdef __cplusplus
#define ALP_API extern "C" __declspec(dllimport)
#else /* __cplusplus */
#define ALP_API __declspec(dllimport)
#endif /* __cplusplus */

#endif

/* Configure the compiler to not add padding bytes to structures: */
#pragma pack(push, 1)

/* /////////////////////////////////////////////////////////////////////////// */
/*	standard parameters */

typedef unsigned long						ALP_ID;
#define ALP_INVALID_ID ((ALP_ID)-1)
	/* "New" ALP API versions set ALP_ID output parameters to this value on errors.
	On success, they avoid this code as valid ALP_ID (device, sequence, or queue ID).
	ALP_DEFAULT is 0, so it may be good to have a different special value */

#define ALP_DEFAULT				0L

#define ALP_ENABLE				1L


/* /////////////////////////////////////////////////////////////////////////// */
/*	return codes */

#define ALP_OK				0x00000000L		/* successful execution */
#define ALP_NOT_ONLINE			1001L		/* The specified ALP has not been found or is not ready. */
#define ALP_NOT_IDLE			1002L		/* The ALP is not in idle state. */
#define ALP_NOT_AVAILABLE		1003L		/* The specified ALP identifier is not valid. */
#define ALP_NOT_READY			1004L		/* The specified ALP is already allocated. */
#define ALP_PARM_INVALID		1005L		/* One of the parameters is invalid. */
#define ALP_ADDR_INVALID		1006L		/* Error accessing user data. */
#define ALP_MEMORY_FULL			1007L		/* The requested memory is not available. */
#define ALP_SEQ_IN_USE			1008L		/* The sequence specified is currently in use. */
#define ALP_HALTED				1009L		/* The ALP has been stopped while image data transfer was active. */
#define ALP_ERROR_INIT			1010L		/* Initialization error. */
#define ALP_ERROR_COMM			1011L		/* Communication error. */
#define ALP_DEVICE_REMOVED		1012L		/* The specified ALP has been removed. */
#define ALP_NOT_CONFIGURED		1013L		/* The onboard FPGA is not configured. */
#define ALP_LOADER_VERSION		1014L		/* The function is not supported by this version of the driver file VlxUsbLd.sys. */
#define ALP_ERROR_POWER_DOWN	1018L		/* waking up the DMD from PWR_FLOAT did not work (ALP_DMD_POWER_FLOAT) */
#define ALP_DRIVER_VERSION		1019L		/* Support in ALP drivers missing. Update drivers and power-cycle device. */
#define ALP_SDRAM_INIT			1020L		/* SDRAM Initialization failed. */
#define ALP_CONFIG_MISMATCH		1021L		/* The device is not properly configured for a function call with the specified parameters */

#define ALP_ERROR_UNKNOWN		1999L		/* reserved */


/* codes for ALP_DEV_STATE in AlpDevInquire */

#define ALP_DEV_BUSY			1100L		/* the ALP is displaying a sequence or image data download is active */
#define ALP_DEV_READY			1101L		/* the ALP is ready for further requests */
#define ALP_DEV_IDLE			1102L		/* the ALP is in wait state */


/* codes for ALP_PROJ_STATE in AlpProjInquire */

#define ALP_PROJ_ACTIVE			1200L		/* ALP projection active */
#define ALP_PROJ_IDLE			1201L		/* no projection active */


/* /////////////////////////////////////////////////////////////////////////// */
/*	AlpDevControl, AlpDevControlEx, and AlpDevInquire */
/*	ControlTypes from 2000 and from 2500 */

	/* General device information */
#define ALP_DEVICE_NUMBER			2000L	/* Serial number of the ALP device */
#define ALP_VERSION					2001L	/* Version number of the ALP device */
#define ALP_DEV_STATE				2002L	/* current ALP status, see above */
#define ALP_AVAIL_MEMORY			2003L	/* ALP on-board sequence memory available for further sequence */

	/* Temperatures. Data format: signed long with 1 LSB=1/256 °C */
#define ALP_DDC_FPGA_TEMPERATURE	2050L	/* DLPC410 / DLPC910 FPGAs Temperature Diode */
#define ALP_APPS_FPGA_TEMPERATURE	2051L	/* Application FPGAs Temperature Diode */
#define ALP_PCB_TEMPERATURE			2052L	/* Board temperature. */

#define ALP_MAX_DDC_FPGA_TEMPERATURE	2145L	/*  maximal recommended DLPC410 / DLPC910 FPGA temperature */
#define ALP_MAX_APPS_FPGA_TEMPERATURE	2146L	/*  maximal recommended Application FPGA temperature */
#define ALP_MAX_PCB_TEMPERATURE			2147L	/*  maximal recommended Board temperature */

	/* GPIO pins */
#define ALP_SYNCH_POLARITY			2004L	/* Select frame synch output signal polarity */
#define ALP_TRIGGER_EDGE			2005L	/* Select active input trigger edge (slave mode) */
#define ALP_LEVEL_HIGH				2006L	/* Active high synch output */
#define ALP_LEVEL_LOW				2007L	/* Active low synch output */
#define ALP_EDGE_FALLING			2008L	/* High to low signal transition */
#define ALP_EDGE_RISING 			2009L	/* Low to high signal transition */

#define ALP_PWM_LEVEL				2063L	/* PWM pin duty-cycle as percentage: 0..100%; after AlpDevAlloc: 0% */

#define ALP_DEV_DYN_SYNCH_OUT_WATCHDOG 2088L	/* Sync Output Time-Out Watchdog */

#define ALP_DEV_DYN_SYNCH_OUT1_GATE	2023L	/* AlpDevControlEx, tAlpDynSynchOutGate */
#define ALP_DEV_DYN_SYNCH_OUT2_GATE	2024L	/* AlpDevControlEx, tAlpDynSynchOutGate */
#define ALP_DEV_DYN_SYNCH_OUT3_GATE	2025L	/* AlpDevControlEx, tAlpDynSynchOutGate */

struct tAlpDynSynchOutGate
{	/* function AlpDevControlEx, ControlTypes ALP_DEV_DYN_SYNCH_OUT[1..3]_GATE
	   Configure compiler to not insert padding bytes! (e.g. #pragma pack) */
	char unsigned Period;		/* #Period=1..16 enables output; 0: tri-state */
	char unsigned Polarity;		/* 0: active pulse is low, 1: high */
	char unsigned Gate[16];		/* #Period number of bytes; each one is 0 or 1
								Only the first #Period bytes are used! */
};

	/* USB interface state */
#define ALP_USB_CONNECTION		2016L	/* Re-connect after a USB interruption */
#define ALP_USB_DISCONNECT_BEHAVIOUR 2078L	/* Values: ALP_USB_IGNORE or ALP_USB_RESET */
#define ALP_USB_IGNORE			1L	/* continue running sequence display */
#define ALP_USB_RESET			2L	/* default: stop running sequences and DLP */

	/* DMD type information */
#define ALP_DEV_DMDTYPE			2021L		/* Select DMD type; only allowed for a new allocated ALP-3 device */
#define ALP_DMDTYPE_XGA			   1L		/* 1024*768 mirror pixels (0.7" Type A, D3000) */
#define ALP_DMDTYPE_SXGA_PLUS	   2L		/* 1400*1050 mirror pixels (0.95" Type A, D3000) */
#define ALP_DMDTYPE_1080P_095A	   3L		/* 1920*1080 mirror pixels (0.95" Type A, DLP9500 for D4x00) */
#define ALP_DMDTYPE_XGA_07A		   4L		/* 1024*768 mirror pixels (0.7" Type A, DLP7000 for D4x00) */
#define ALP_DMDTYPE_XGA_055A	   5L		/* 1024*768 mirror pixels (0.55" Type A, D4x00) */
#define ALP_DMDTYPE_XGA_055X	   6L		/* 1024*768 mirror pixels (0.55" Type X, D4x00) */
#define ALP_DMDTYPE_WUXGA_096A	   7L		/* 1920*1200 mirror pixels (0.96" Type A, D4100) */
#define ALP_DMDTYPE_WQXGA_400MHZ_090A 8L	/* 2560*1600 mirror pixels (0.90" Type A, DLP9000X for DLPC910) at standard clock rate (400 MHz) */
#define ALP_DMDTYPE_WQXGA_480MHZ_090A 9L	/* DLP9000X at extended clock rate (480 MHz); WARNING: This mode requires temperature control of DMD */
#define ALP_DMDTYPE_1080P_065A	  10L		/* 1920*1080 mirror pixels (0.65" Type A, DLP6500FLQ for DLPC910) */
#define ALP_DMDTYPE_1080P_065_S600 11L		/* 1920*1080 mirror pixels (0.65" S600, DLP6500FYE for DLPC910) */
#define ALP_DMDTYPE_WXGA_S450     12L		/* 1280*800 mirror pixels (0.65" s450, DLP650LNIR for DLPC410) */
#define ALP_DMDTYPE_DLPC910REV	 254L		/* A DLPC910 Update required for controlling this DMD type. Contact ViALUX. */
#define ALP_DMDTYPE_DISCONNECT	 255L		/* Behaves like 1080p */

#define ALP_DEV_DISPLAY_HEIGHT	2057L		/* number of mirror rows on the DMD */
#define ALP_DEV_DISPLAY_WIDTH	2058L		/* number of mirror columns on the DMD */

#define ALP_DEV_DMD_MODE        2064L		/* query/set DMD PWR_FLOAT mode, valid options: ALP_DMD_RESUME, ALP_DMD_POWER_FLOAT */
#define ALP_DMD_RESUME			   0L		/* normal operation, wake up DMD; on loss of supply voltage, an auto-shutdown safely switches off DMD */
#define ALP_DMD_POWER_FLOAT        1L		/* power down, release micro mirrors from deflected to flat state */

	/* DYN_SYNCH_OUT */
#define ALP_DEV_GPIO5_PIN_MUX                2062L
#define ALP_GPIO_STATIC_LOW						0
#define ALP_GPIO_STATIC_HIGH					1
#define ALP_GPIO_DYN_SYNCH_OUT_ACTIVE_LOW		16 // see also ALP_SEQ_DYN_SYNCH_OUT_PERIOD
#define ALP_GPIO_DYN_SYNCH_OUT_ACTIVE_HIGH		17 // see also ALP_SEQ_DYN_SYNCH_OUT_PERIOD


/* In order to set the ALP_BITPLANE_LUT_MODE to ALP_BITPLANE_LUT_ROW, a special sequence configuration must be activated for the corresponding sequence first.
In order to do so, a call to AlpDevControl with the ControlType ALP_SEQ_CONFIG is required before allocation of the sequence with AlpSeqAlloc */
#define ALP_SEQ_CONFIG					2153L
#define ALP_SEQ_CONFIG_DEFAULT			ALP_DEFAULT		/*  Default configuration */
#define ALP_SEQ_CONFIG_BITPLANE_LUT_ROW	1L				/*	Special sequence configuration needed for row based bit plane lookup table */

/* /////////////////////////////////////////////////////////////////////////// */
/*	AlpSeqControl */
/*	ControlTypes from 2100 */

	/* Selection of Display Data */
#define ALP_SEQ_REPEAT			2100L	/* Configure the number of sequence iterations for non-continuous display of a sequence (AlpProjStart). */
#define ALP_FIRSTFRAME			2101L	/* First image of this sequence to be displayed. */
#define ALP_LASTFRAME			2102L	/* Last image of this sequence to be displayed. */

	/* Gray-Scale generation */
#define ALP_BITNUM				2103L	/* A sequence can be displayed with reduced bit depth for faster speed. */

#define ALP_BIN_MODE			2104L	/* Binary mode: select from ALP_BIN_NORMAL and ALP_BIN_UNINTERRUPTED */
#define ALP_BIN_NORMAL			2105L	/* Normal operation with programmable dark phase */
#define ALP_BIN_UNINTERRUPTED	2106L	/* Operation without dark phase */

#define ALP_PWM_MODE			2107L	/* ALP_DEFAULT, ALP_FLEX_PWM */
#define ALP_FLEX_PWM			   3L	/* ALP_PWM_MODE: all bit planes of the sequence are displayed as
										   fast as possible in binary uninterrupted mode;
										   Use ALP_SLAVE mode to achieve a custom pulse-width modulation timing for generating gray-scale */

#define	ALP_BITPLANE_LUT_MODE ALP_PWM_MODE /* Determine Bit Plane LookUp Table (BPLUT) usage */
#define	ALP_BITPLANE_LUT_DEFAULT   0L	/* Use standard gray scale mode, no BPLUT (default) */
#define	ALP_BITPLANE_LUT_FRAME	   6L	/* Use BPLUT for frame addressing: select a bitplane for each frame */
#define	ALP_BITPLANE_LUT_ROW   	   7L	/* Use BPLUT for row addressing: select a bitplane for each row */

#define ALP_BITPLANE_LUT_ENTRIES 2108L	/* Number of used LUT entries in ALP_BITPLANE_LUT_FRAME mode */

	/* Data transfer */
#define ALP_DATA_FORMAT			2110L	/* Data format and alignment */
#define ALP_DATA_MSB_ALIGN		   0L	/* Data is MSB aligned (default) */
#define ALP_DATA_LSB_ALIGN		   1L	/* Data is LSB aligned */
#define ALP_DATA_BINARY_TOPDOWN	   2L	/* Data is packed binary, top row first; bit7 of a byte = leftmost of 8 pixels */
#define ALP_DATA_BINARY_BOTTOMUP   3L	/* Data is packed binary, bottom row first */

#define	ALP_SEQ_PUT_LOCK		2119L	/* ALP_DEFAULT: Lock Sequence Memory in AlpSeqPut;
										   Not ALP_DEFAULT: do not lock, instead allow writing sequence image data even currently displayed */

	/* Scrolling mode */
#define ALP_LINE_INC			2113L	/* Line shift value for the next frame. ALP_DEFAULT disables scrolling mode. */
#define ALP_FIRSTLINE			2111L	/* Start line in ALP_FIRSTFRAME */
#define ALP_LASTLINE			2112L	/* Stop line in ALP_LASTFRAME */
#define ALP_SCROLL_FROM_ROW		2123L	/* combined value from ALP_FIRSTFRAME and ALP_FIRSTLINE */
#define ALP_SCROLL_TO_ROW		2124L	/* combined value from ALP_LASTFRAME and ALP_LASTLINE */

#define ALP_X_OFFSET			2359L	/* shift image to left;
	Effective after AlpProjStart[Cont] (synchronously); requires AlpSeqControl (ALP_X_OFFSET_SELECT, ALP_X_OFFSET_SEQ);
	Asynchronous version available (AlpProjControl(ALP_X_OFFSET)) */
#define ALP_X_OFFSET_SELECT		2154L	/* use global, asynchronous ALP_X_OFFSET setting (AlpProjControl) or sequence setting (AlpSeqControl, effective after AlpProjStart) */
#define ALP_X_OFFSET_GLOBAL		ALP_DEFAULT
#define ALP_X_OFFSET_SEQ		1

	/* Frame Look Up Table mode (FLUT): (see also ALP_FLUT_SET_MEMORY) */
#define	ALP_FLUT_MODE			2118L	/* Enable Frame Look Up Table for a sequence */
#define	ALP_FLUT_NONE			   0L	/* linear addressing, do not use FLUT (default) */
#define	ALP_FLUT_9BIT			   1L	/* Use FLUT for frame addressing: 9-bit entries */
#define	ALP_FLUT_18BIT			   2L	/* Use FLUT for frame addressing: 18-bit entries */

#define	ALP_FLUT_ENTRIES9		2120L	/* number of FLUT entries; default=1;
										supports all values from 1 to ALP_FLUT_MAX_ENTRIES9 */
#define	ALP_FLUT_OFFSET9		2122L	/* offset of FLUT index; default=0;
										   Offset supports multiples of 256 */
/* Notes on ALP_FLUT_18BIT:				   The effective index is half of the 9-bit index.
										   --> "ALP_FLUT_ENTRIES18" and "ALP_FLUT_FRAME_OFFSET18" are 9-bit settings divided by 2.
										   The API does not reject overflow! (FRAME_OFFSET+ENTRIES > MAX_ENTRIES).
										   The user is responsible for correct settings. */

	/* Area of Interest (AOI) */
#define ALP_SEQ_DMD_LINES		2125L	/* Area of Interest: Value = MAKELONG(AOI_StartRow, AOI_RowCount) */

	/* Display Data Processing */
#define ALP_X_SHEAR_SELECT		2132L	/* ALP_DEFAULT = off, ALP_ENABLE = quarter 1, else 2, 3, 4 for other quarters (see also tAlpShearTable)  */

#define ALP_DMD_MASK_SELECT		2134L	/* ALP_DEFAULT or one of the codes below */
#define ALP_DMD_MASK_16X16		1L
#define ALP_DMD_MASK_16X8		2L
#define ALP_DMD_MASK_XY(X, Y)	(Y*65536 + X)	/* mask blocks are X DMD pixels wide and Y DMD pixels high. */

	/* DYN_SYNCH_OUT */
#define ALP_SEQ_DYN_SYNCH_OUT_PERIOD         2150L
#define ALP_SEQ_DYN_SYNCH_OUT_PULSEWIDTH     2151L

/* /////////////////////////////////////////////////////////////////////////// */
/*	AlpSeqInquire */
/*	additional InquireTypes */

	/* General sequence information */
#define ALP_BITPLANES			2200L	/* Bit depth of the pictures in the sequence */
#define ALP_PICNUM				2201L	/* Number of pictures in the sequence */

	/* Timing */
#define ALP_PICTURE_TIME		2203L	/* Time between the start of consecutive pictures in the sequence in microseconds,
										the corresponding in frames per second is
										picture rate [fps] = 1 000 000 / ALP_PICTURE_TIME [µs] */
#define ALP_ILLUMINATE_TIME		2204L	/* Duration of the display of one picture in microseconds */
#define ALP_SYNCH_DELAY			2205L	/* Delay of the start of picture display with respect
										to the frame synch output (master mode) in microseconds */
#define ALP_SYNCH_PULSEWIDTH	2206L	/* Duration of the active frame synch output pulse in microseconds */
#define ALP_TRIGGER_IN_DELAY	2207L	/* Delay of the start of picture display with respect to the
										active trigger input edge in microseconds */
#define ALP_MAX_SYNCH_DELAY		2209L	/* Maximum delay between frame synch output to projection in microseconds */
#define ALP_MAX_TRIGGER_IN_DELAY	2210L	/* Maximum delay from trigger input to projection in microseconds */

#define ALP_MIN_PICTURE_TIME	2211L	/* Minimum time between the start of consecutive pictures in microseconds */
#define ALP_MIN_ILLUMINATE_TIME	2212L	/* Minimum duration of the display of one picture in microseconds,
										depends on ALP_BITNUM, ALP_BIN_MODE, and ALP_SEQ_DMD_LINES. */
#define ALP_MAX_PICTURE_TIME	2213L	/* Maximum value of ALP_PICTURE_TIME */

										/* ALP_PICTURE_TIME = ALP_ON_TIME + ALP_OFF_TIME */
										/* ALP_ON_TIME may be smaller than ALP_ILLUMINATE_TIME */
#define ALP_ON_TIME				2214L	/* Total active projection time per frame */
#define ALP_OFF_TIME			2215L	/* Total inactive time per frame */


/* /////////////////////////////////////////////////////////////////////////// */
/*	AlpSeqPutEx */

struct tAlpLinePut
{	/* AlpSeqPutEx */
	long TransferMode;	/* common first member of UserStructPtr */
	long PicOffset;
	long PicLoad;
	long LineOffset;
	long LineLoad;
};
#define ALP_PUT_LINES	1UL	/* tAlpLinePut::TransferMode */


/* /////////////////////////////////////////////////////////////////////////// */
/*	AlpProjInquire & AlpProjControl & ...Ex */
/*	InquireTypes, ControlTypes & Values */

	/* Display state */
#define ALP_PROJ_STATE			2400L	/* Inquire only */

#define ALP_PROJ_ABORT_ASYNC	2345L	/* abort current display immediately, asynchronous to any frame;
										   see also ALP_PROJ_ABORT_SEQUENCE and ALP_PROJ_ABORT_FRAME */

#define ALP_PROJ_WAIT_UNTIL		2323L	/* When does AlpProjWait complete regarding the last frame? or after picture time of last frame */
#define ALP_PROJ_WAIT_PIC_TIME	0L		/* ALP_DEFAULT: AlpProjWait returns after picture time */
#define ALP_PROJ_WAIT_ILLU_TIME	1L		/* AlpProjWait returns after illuminate time (except binary uninterrupted sequences, because an "illuminate time" is not applicable there) */

	/* Configure synchronization */
#define	ALP_PROJ_MODE			2300L	/* Select from ALP_MASTER and ALP_SLAVE mode */
#define	ALP_MASTER				2301L	/* The ALP operation is controlled by internal */
										/* timing, a synch signal is sent out for any */
										/* picture displayed */
#define	ALP_SLAVE				2302L	/* The ALP operation is controlled by external */
										/* trigger, the next picture in a sequence is */
										/* displayed after the detection of an external */
										/* input trigger signal. */
#define ALP_PROJ_STEP			2329L	/* ALP operation should run in ALP_MASTER mode,
											but each frame is repeatedly displayed
											until a trigger event is received.
											Values (conditions): ALP_LEVEL_HIGH |
											LOW, ALP_EDGE_RISING | FALLING.
											ALP_DEFAULT disables the trigger and
											makes the sequence progress "as usual".
											If an event is "stored" in edge mode due
											to a past edge, then it will be
											discarded during
											AlpProjControl(ALP_PROJ_STEP). */

	/* Transfer Frame Look Up Table (FLUT): see also ALP_FLUT_MODE */
#define	ALP_FLUT_MAX_ENTRIES9	2324L	/* Inquire FLUT size */
#define ALP_FLUT_WRITE_9BIT		2325L	/* 9-bit look-up table entries. AlpProjControlEx, tFlutWrite */
#define ALP_FLUT_WRITE_18BIT	2326L	/* 18-bit look-up table entries. AlpProjControlEx, tFlutWrite  */

struct tFlutWrite
{	/* function AlpProjControlEx, ControlTypes ALP_FLUT_WRITE_9BIT, ALP_FLUT_WRITE_18BIT
	   (both versions share the same data type) */
	long nOffset;				/* first LUT entry to transfer (write FrameNumbers[0] to LUT[nOffset]): */
	long nSize;					/* number of 9-bit or 18-bit entries to transfer;
								For nSize=ALP_DEFAULT(0) the API sets nSize to its maximum value. This
								requires nOffset=0  */
	/* nOffset+nSize must not exceed ALP_FLUT_MAX_ENTRIES9 (ALP_FLUT_WRITE_9BIT)
	or ALP_FLUT_MAX_ENTRIES9/2 (ALP_FLUT_WRITE_18BIT). */

	long unsigned FrameNumbers[4096]; /* The ALP API reads only the first nSize entries from this array. It
								extracts 9 or 18 least significant bits from each entry. */
};

	/* Display Data Processing */
#define	ALP_PROJ_INVERSION		2306L	/* Reverse dark into bright */
#define	ALP_PROJ_UPSIDE_DOWN	2307L	/* Flip the pictures upside down */
#define ALP_PROJ_LEFT_RIGHT_FLIP 2346L	/* Flip pictures left/right */

#define ALP_X_OFFSET	2359L /* shift all frames to display by this number of columns towards left edge of DMD;
	fill columns from opposite edge with zeros (=black data);
	Effective immediately (asynchronously); can be disabled for a sequence by AlpSeqControl (ALP_X_OFFSET_SELECT);
	Synchronous version available (AlpSeqControl(ALP_X_OFFSET));
	Valid values: -512..+511 (i.e. from far to right over 0 (no shift) to far to left */
#define ALP_Y_OFFSET	2360L /* shift all frames to display by this number of rows towards TOP edge of DMD;
	Fill bottom rows from next frame;
	no range check is made: improper settings (ALP_Y_OFFSET+ALP_SCROLL_TO_ROW > (PicNum-1)*AOI_RowCount)
	cause shifting in invalid data at the end of the sequence;
	Effective immediately (asynchronously);
	offset is added to ALP_SCROLL_FROM_ROW sequence setting;
	Valid values: 0..4095 */

#define ALP_X_SHEAR				2337L	/* AlpProjControlEx, tAlpShearTable, see also ALP_X_SHEAR_SELECT */
struct tAlpShearTable
{	/* AlpProjControlEx, ControlType ALP_X_SHEAR */
	long nOffset;
	long nSize;
	/* one distance is used for each DMD row; the table can store enough values for multiple DMDs;
	use AlpSeqControl (ALP_X_SHEAR_SELECT) to select from four quarters:
	Quarter 1 (start at index 0), Q2 (2048), Q3 (4096), Q4 (6144)  */
	signed long nShiftDistance[8192];			/* values range from -512 to 511 */
};

#define ALP_DMD_MASK_WRITE_16K	2351L	/* AlpProjControlEx, tAlpDmdMask16K, see also ALP_DMD_MASK_SELECT */
struct tAlpDmdMask16K
{	/* AlpProjControlEx, ControlType ALP_DMD_MASK_WRITE_16K */
	long nBlockWidth;				/* horizontal resolution: DMD pixels per mask bit */
	long nRowOffset;				/* Bitmap position in the mask, ALP_DEFAULT=0 */
	long nRowCount;					/* rows to be written or ALP_DEFAULT */
	char unsigned Bitmap[16384];	/* each bit controls a block of nBlockWidth*Y DMD pixels */
};

#define ALP_DMD_MASK_WRITE		2339L	/* AlpProjControlEx, tAlpDmdMask; see also ALP_DMD_MASK_WRITE_16K */
struct tAlpDmdMask
{	/* AlpProjControlEx, ControlType ALP_DMD_MASK_WRITE */
	long nRowOffset;				/* Bitmap position in a 16x16 mask, ALP_DEFAULT=0 */
	long nRowCount;					/* rows to be written or ALP_DEFAULT (full DMD 16x16 mask) */
	char unsigned Bitmap[2048];		/* each bit controls a block of 16*Y DMD pixels */
};

#define ALP_BPLUT_MAX_ENTRIES		2356L /* InquireType only */
#define	ALP_BPLUT_WRITE  			2357L /* for use with AlpProjControlEx, tBplutWrite; see also ALP_BITPLANE_LUT_MODE */
struct tBplutWrite {
	/* AlpProjControlEx, ControlType ALP_BPLUT_WRITE */
	long nOffset;
	long nSize;
	short unsigned BitPlanes[2048];	/* lookup table data */
}; 


	/* Sequence Queue API Extension: */
#define ALP_PROJ_QUEUE_MODE		2314L
#define ALP_PROJ_LEGACY			0L		/* ALP_DEFAULT: emulate legacy mode: 1 waiting position. AlpProjStart replaces enqueued and still waiting sequences */
#define ALP_PROJ_SEQUENCE_QUEUE	1L		/* manage active sequences in a queue */

#define ALP_PROJ_QUEUE_ID			2315L	/* provide the QueueID (ALP_ID) of the most recently enqueued sequence (or ALP_INVALID_ID) */
#define ALP_PROJ_QUEUE_MAX_AVAIL	2316L	/* total number of waiting positions in the sequence queue */
#define ALP_PROJ_QUEUE_AVAIL		2317L	/* number of available waiting positions in the queue;
											   bear in mind that when a sequence runs, it is already
												dequeued and does not consume a waiting position any more */
#define ALP_PROJ_PROGRESS		2318L	/* tAlpProjProgress: inquire detailed progress of the running sequence and the queue */
#define ALP_PROJ_RESET_QUEUE	2319L	/* Remove all enqueued sequences from the queue. The currently running sequence is not affected. ControlValue must be ALP_DEFAULT */
#define ALP_PROJ_ABORT_SEQUENCE	2320L	/* abort the current sequence (ControlValue=ALP_DEFAULT) or a specific sequence (ControlValue=QueueID); abort after last frame of current iteration */
#define ALP_PROJ_ABORT_FRAME	2321L	/* similar, but abort after next frame */
										/* Only one abort request can be active at a time. If it is requested to
										   abort another sequence before the old request is completed, then
										   AlpProjControl returns ALP_NOT_IDLE. (Please note, that AlpProjHalt
										   and AlpDevHalt work anyway.) If the QueueID points to a sequence
										   behind an indefinitely started one (AlpProjStartCont) then it returns
										   ALP_PARM_INVALID in order to prevent dead-locks. */
struct tAlpProjProgress
{	/* AlpProjInquireEx, InquireType ALP_PROJ_PROGRESS */
	ALP_ID CurrentQueueId;
	ALP_ID SequenceId;						/* Consider that a sequence can be enqueued multiple times! */
	unsigned long nWaitingSequences;		/* number of sequences waiting in the queue */

	/* track iterations and frames: see the API description for details, e.g. on incomplete counters. */
	unsigned long nSequenceCounter;			/* number of iterations to be done */
	unsigned long nSequenceCounterUnderflow;/* nSequenceCounter can underflow (for indefinitely long Sequences: AlpProjStartCont);
											   nSequenceCounterUnderflow is 0 before, and non-null afterwards */
	unsigned long nFrameCounter;			/* frames left inside current iteration */

	unsigned long nPictureTime;				/* micro seconds of each frame; this is reported, because the picture time
											   of the original sequence could already have changed in between */
	unsigned long nFramesPerSubSequence;	/* Each sequence iteration displays this number of frames. It is reported to the
											   user just for convenience, because it depends on different parameters. */

	unsigned long nFlags;					/* combination of ALP_FLAG_SEQUENCE_ABORTING | SEQUENCE_INDEFINITE | QUEUE_IDLE | FRAME_FINISHED */
};
#define ALP_FLAG_QUEUE_IDLE				   1UL	/* tAlpProjProgress::nFlags */
#define ALP_FLAG_SEQUENCE_ABORTING		   2UL	/* tAlpProjProgress::nFlags */
#define ALP_FLAG_SEQUENCE_INDEFINITE	   4UL	/* tAlpProjProgress::nFlags; AlpProjStartCont: this sequence runs indefinitely long, until aborted */
#define ALP_FLAG_FRAME_FINISHED			   8UL	/* tAlpProjProgress::nFlags; illumination of last frame finished, picture time still progressing */
#define ALP_FLAG_RSVD0					  16UL	/* tAlpProjProgress::nFlags; reserved */


/* /////////////////////////////////////////////////////////////////////////// */
/*	AlpLedAlloc */
/*	LedTypes */

#define ALP_HLD_PT120_RED		0x0101l	/* obsolete, replaced by PT120 RAX in 2016 */
#define ALP_HLD_PT120_RAX		0x010cl
#define ALP_HLD_PT120_GREEN		0x0102l
#define ALP_HLD_PT120_BLUE		0x0103l	/* obsolete, devices shipped since 2013 have the TE package */
#define ALP_HLD_PT120TE_BLUE	0x0107l	/* thermally enhanced (TE) package */

#define ALP_HLD_CBT90_UV		0x0109l
#define ALP_HLD_PT120_390		ALP_HLD_CBT120_UV	/* Alias for compatibility of "old" source code */
#define ALP_HLD_CBT120_UV		0x0104l
#define ALP_HLD_CBM120_UV365	0x010al	/* UV (365..375nm) LED with max continuous current of up to 12A */
#define ALP_HLD_CBM120_UV		0x010bl	/* UV (>=380nm) LED with max continuous current of up to 18A */

#define ALP_HLD_CBM90X33_IRD	0x010el	/* NIR (850nm) LED, continuous drive current 13.5A */
#define ALP_HLD_CBM120_FR		0x0110l	/* FR  (730nm) LED, continuous drive current 18A */	

#define ALP_HLD_CBT90_WHITE		0x0106l
#define ALP_HLD_CBT140_WHITE	0x0108l	/* 14mm² round emitting aperture; absolute maximum = continuous drive current = 21A */

#define ALP_HLD_C_MULTI_405GR	0x010dl
#define ALP_HLD_C_MULTI_RGB		0x010fl /* This type represents a HLD that is connected to three LEDs in parallel: PT-121-B, PT121-G, CBT-90-R, continuous drive current 18A */

#define tAlpHldPt120AllocParams tAlpHldAllocParams
struct tAlpHldAllocParams
{	/* AlpLedAlloc, AlpLedInquireEx(ALP_LED_ALLOC_PARAMS) */
	/* Type of *UserStructPtr for AlpLedAlloc when LedType is one of the ALP_HLD_* types.
	   These LedTypes have DEFAULT alloc parameters, so UserStructPtr is allowed to be NULL. */
	long I2cDacAddr;
	long I2cAdcAddr;
};




/* /////////////////////////////////////////////////////////////////////////// */
/*	AlpLedControl, AlpLedInquire, ...Ex */
/*	ControlTypes */

#define ALP_LED_SET_CURRENT			1001l	/* set up nominal LED current. Value = milliamperes */
#define ALP_LED_BRIGHTNESS			1002l	/* set up brightness on base of ALP_LED_CURRENT.  Value = percent (0..133%) */
#define ALP_LED_FORCE_OFF			1003l	/* HLD: A small LED current could flow even if set to zero.
											   This could be forced off by explicitly disabling the LED driver.
											   But it takes several milliseconds to enable again. */
#define ALP_LED_AUTO_OFF			   0l	/* Default: Disable the LED driver if, and only if, SET_CURRENT*BRIGHTNESS==0. */
#define ALP_LED_OFF					   1l	/* Disable LED driver. This ensures that no current is output to the LED. */
#define ALP_LED_ON					   2l	/* Enable LED driver. Use this if it is required to wake up quickly. */

/* AlpLedInquire: additional InquireTypes AlpLedInquire */
/* ALP_LED_SET_CURRENT: slightly differs from the value used in AlpLedControl due to arithmetic model */
#define ALP_LED_TYPE				1101l	/* LedType of this LedId */
#define ALP_LED_MEASURED_CURRENT	1102l	/* measured LED current in milliamperes */
#define ALP_LED_TEMPERATURE_REF		1103l	/* measured temperature at the sensor on the LED board*/
#define ALP_LED_TEMPERATURE_JUNCTION 1104l	/* calculated LED junction temperature on base of
												   ALP_LED_TEMPERATURE_REF and a thermal model according to LED Type*/

/* AlpLedControlEx: ControlTypes */
/* currently none. */

/* AlpLedInquireEx: InquireTypes */
#define ALP_LED_ALLOC_PARAMS		2101l	/* retrieve actual alloc parameters; especially useful if omitted in the AlpLedAlloc call */
									/* Note: UserStructPtr must point to a structure according to ALP_LED_TYPE, e.g. tAlpHldPt120AllocParams */

									
									
/* /////////////////////////////////////////////////////////////////////////// */
/*	COMPATIBILITY for old source code: */
#ifndef ALP_DISABLE_OLD_SYMBOLS

/* Rename TRIG to SYNCH, but preserve the "old" denominators for compatibility. */
/* These controls handle output pins, not input, so "synch" is more appropriate than "trigger". */
#define ALP_DEV_DYN_TRIG_OUT1_GATE ALP_DEV_DYN_SYNCH_OUT1_GATE
#define ALP_DEV_DYN_TRIG_OUT2_GATE ALP_DEV_DYN_SYNCH_OUT2_GATE
#define ALP_DEV_DYN_TRIG_OUT3_GATE ALP_DEV_DYN_SYNCH_OUT3_GATE
typedef struct tAlpDynSynchOutGate tAlpDynTrigOutGate;
#define ALP_TRIGGER_POLARITY	ALP_SYNCH_POLARITY
#define ALP_TRIGGER_DELAY		ALP_SYNCH_DELAY
#define ALP_TRIGGER_PULSEWIDTH	ALP_SYNCH_PULSEWIDTH
#define ALP_MAX_TRIGGER_DELAY	ALP_MAX_SYNCH_DELAY
/* These controls handle "trigger" input pin. */
#define ALP_VD_EDGE				ALP_TRIGGER_EDGE
#define ALP_VD_TIME_OUT			ALP_TRIGGER_TIME_OUT
#define ALP_VD_DELAY			ALP_TRIGGER_IN_DELAY
#define ALP_MAX_VD_DELAY		ALP_MAX_TRIGGER_IN_DELAY
#define ALP_SLAVE_VD			ALP_SLAVE
/* Typo made in old documentation (ALP API description) */
#define ALP_SEQ_REPETE ALP_SEQ_REPEAT
#endif /* ALP_DISABLE_OLD_SYMBOLS */


/* /////////////////////////////////////////////////////////////////////////// */
/*	ALP API Functions */

	/* Device */
ALP_API long ALP_ATTR AlpDevAlloc( long DeviceNum, long InitFlag, ALP_ID* DeviceIdPtr);
ALP_API long ALP_ATTR AlpDevHalt( ALP_ID DeviceId);
ALP_API long ALP_ATTR AlpDevFree( ALP_ID DeviceId);

ALP_API long ALP_ATTR AlpDevControl( ALP_ID DeviceId, long ControlType, long ControlValue);
ALP_API long ALP_ATTR AlpDevControlEx( ALP_ID DeviceId, long ControlType, void *UserStructPtr );
ALP_API long ALP_ATTR AlpDevInquire( ALP_ID DeviceId, long InquireType, long *UserVarPtr);


	/* Sequence */
ALP_API long ALP_ATTR AlpSeqAlloc( ALP_ID DeviceId, long BitPlanes, long PicNum,  ALP_ID *SequenceIdPtr);
ALP_API long ALP_ATTR AlpSeqFree( ALP_ID DeviceId, ALP_ID SequenceId);

ALP_API long ALP_ATTR AlpSeqControl( ALP_ID DeviceId, ALP_ID SequenceId,  long ControlType, long ControlValue);
ALP_API long ALP_ATTR AlpSeqTiming( ALP_ID DeviceId, ALP_ID SequenceId,  long IlluminateTime, 
		long PictureTime, long SynchDelay, long SynchPulseWidth, long TriggerInDelay);
ALP_API long ALP_ATTR AlpSeqInquire( ALP_ID DeviceId, ALP_ID SequenceId,  long InquireType, 
		long *UserVarPtr);

ALP_API long ALP_ATTR AlpSeqPut( ALP_ID DeviceId, ALP_ID SequenceId, long PicOffset, long PicLoad, 
	    void *UserArrayPtr);
ALP_API long ALP_ATTR AlpSeqPutEx( ALP_ID DeviceId, ALP_ID SequenceId, void *UserStructPtr,
		void *UserArrayPtr);


	/* Projection */
ALP_API long ALP_ATTR AlpProjStart( ALP_ID DeviceId, ALP_ID SequenceId);
ALP_API long ALP_ATTR AlpProjStartCont( ALP_ID DeviceId, ALP_ID SequenceId);
ALP_API long ALP_ATTR AlpProjHalt( ALP_ID DeviceId);
ALP_API long ALP_ATTR AlpProjWait( ALP_ID DeviceId);

ALP_API long ALP_ATTR AlpProjControl( ALP_ID DeviceId, long ControlType, long ControlValue);
ALP_API long ALP_ATTR AlpProjControlEx( ALP_ID DeviceId, long ControlType, void *pUserStructPtr );
ALP_API long ALP_ATTR AlpProjInquire( ALP_ID DeviceId, long InquireType, long *UserVarPtr);
ALP_API long ALP_ATTR AlpProjInquireEx( ALP_ID DeviceId, long InquireType, void *UserStructPtr );


	/* LED API */
/* Find a free LED Driver, and initialize it according to LedType and optional *UserStructPtr (can be NULL) */
ALP_API long ALP_ATTR AlpLedAlloc( ALP_ID DeviceId, long LedType, void *UserStructPtr, ALP_ID *LedId );
/* switch LED off and release LED instance */
ALP_API long ALP_ATTR AlpLedFree( ALP_ID DeviceId, ALP_ID LedId );
/* change LED state / behaviour */
ALP_API long ALP_ATTR AlpLedControl( ALP_ID DeviceId, ALP_ID LedId, long ControlType, long Value );
ALP_API long ALP_ATTR AlpLedControlEx( ALP_ID DeviceId, ALP_ID LedId, long ControlType, void *UserStructPtr);
/* query LED state, setup values, and measured values */
ALP_API long ALP_ATTR AlpLedInquire( ALP_ID DeviceId, ALP_ID LedId, long InquireType, long *UserVarPtr );
ALP_API long ALP_ATTR AlpLedInquireEx( ALP_ID DeviceId, ALP_ID LedId, long InquireType, void *UserStructPtr);


#pragma pack(pop)

/* /////////////////////////////////////////////////////////////////////////// */
#endif  /* _ALP_H_INCLUDED */

