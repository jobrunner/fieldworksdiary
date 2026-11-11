//
//  utmext.h
//  fieldworksdiary
//
//  Created by Jo Brunner on 16.04.16.
//  Copyright © 2016 Jo Brunner. All rights reserved.
//

#ifndef mgrsext_h
#define mgrsext_h

/* ensure proper linkage to c++ programs */
#ifdef __cplusplus
extern "C" {
#endif

    long Get_Latitude_Letter(double latitude, int* letter);
    
    /*
     * The function Break_MGRS_String breaks down an MGRS
     * coordinate string into its component parts.
     *
     *   MGRS           : MGRS coordinate string          (input)
     *   Zone           : UTM Zone                        (output)
     *   Letters        : MGRS coordinate string letters  (output)
     *   Easting        : Easting value                   (output)
     *   Northing       : Northing value                  (output)
     *   Precision      : Precision level of MGRS string  (output)
     */
    long Break_MGRS_String (char* MGRS,
                            long* Zone,
                            long Letters[3],
                            double* Easting,
                            double* Northing,
                            long* Precision);
#ifdef __cplusplus
}
#endif

#endif /* mgrsext_h */
