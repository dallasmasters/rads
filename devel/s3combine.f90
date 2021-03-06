!-----------------------------------------------------------------------
! Copyright (c) 2011-2016  Remko Scharroo
! See LICENSE.TXT file for copying and redistribution conditions.
!
! This program is free software: you can redistribute it and/or modify
! it under the terms of the GNU Lesser General Public License as
! published by the Free Software Foundation, either version 3 of the
! License, or (at your option) any later version.
!
! This program is distributed in the hope that it will be useful,
! but WITHOUT ANY WARRANTY; without even the implied warranty of
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
! GNU Lesser General Public License for more details.
!-----------------------------------------------------------------------

!*s3combine -- Combine (and split) Sentinel-3 files into pass files
!
! Read Sentinel-3 standard_measurements.nc or reduced_measurements.nc
! granules and combine them (and split them) into pass files.
! The input file names are read from
! standard input. The individual pass files will be named
! <destdir>/cCCC/S3A_*_CCC_PPP_*.nc, where CCC is the cycle number and
! PPP the pass number. The directory <destdir>/cCCC will be created if needed.
!
! This program does not rely on ORF files, like ogdrsplit does.
!-----------------------------------------------------------------------
program s3combine

use rads
use rads_misc
use rads_netcdf
use typesizes
use netcdf

! Scruct to store input file information

type :: fileinfo
	integer(fourbyteint) :: ncid, rec0, rec1, nrec, type
	real(eightbytereal) :: time0, time1, lat0, lat1, lon0, lon1
	character(len=rads_cmdl) :: filenm
end type
type(fileinfo) :: fin(20)

! General variables

type(rads_sat) :: S
type(rads_pass) :: P
character(len=rads_cmdl) :: arg, filenm, dimnm, destdir, product_name, mission_name, xref_orbit_data
character(len=rads_strl) :: exclude_list = ','
character(len=2) :: sat = ''
character(len=26) :: date(3)
integer(fourbyteint), parameter :: mpass = 254 * 500
real(eightbytereal), parameter :: sec2000 = 473299200d0
integer(fourbyteint) :: i0, i, ncid1, nrec, ios, varid, in_max = huge(fourbyteint), nr_passes = 770, &
	pass_number = 0, cycle_number = 0, pass_in, cycle_in, nfile = 0, orbit_type, absolute_pass_number, &
	absolute_rev_number
real(eightbytereal), allocatable :: time(:), lat(:), lon(:)
real(eightbytereal) :: last_time = 0

! Print description, if requested

if (iargc() < 1) then
	write (*,1300)
	stop
endif
1300 format ('s3combine -- Combine/split Sentinel-3 files into pass files'// &
'syntax: s3combine [options] destdir < list'//'where'/ &
'  destdir           : Destination directory (appends c???/*.nc)'/ &
'  list              : List of input files names'// &
'where [options] are:' / &
'  -mMAXREC          : Maximum number of records allowed at input' / &
'  -xVAR1[,VAR2,...] : Exclude variable(s) from copying')

! Read options and destination directory

do i = 1,iargc()
	call getarg (i,arg)
	if (arg(:2) == '-m') then
		read (arg(3:), *, iostat=ios) in_max
	else if (arg(:2) == '-x') then
		exclude_list = trim(exclude_list) // arg(3:len_trim(arg)) // ','
	else
		destdir = arg
	endif
enddo

! Cycle through all input files

do
	read (*,'(a)',iostat=ios) filenm
	if (ios /= 0) exit

! Open the input file

	if (nft(nf90_open(filenm,nf90_nowrite,ncid1))) then
		call rads_message ('Error while opening file: '//filenm)
		cycle
	endif

! Init RADS, just to get some Sentinel-3 parameters.
! Do this only once, and make sure the user is only feeding 3A or 3B files.

	call nfs(nf90_get_att(ncid1,nf90_global,'mission_name',mission_name))
	if (mission_name(:10) /= 'Sentinel 3') then
		call rads_message ('Unknown mission name "'//trim(mission_name)// &
			'"; skipped file: '//filenm)
		call nfs(nf90_close(ncid1))
		cycle
	else if (sat == '') then
		sat = mission_name(10:11)
		call rads_init (S, sat)
	else if (sat /= mission_name(10:11)) then
		call rads_message ('Mission name "'//trim(mission_name)// &
			'" not same as former; skipped file: '//filenm)
		call nfs(nf90_close(ncid1))
		cycle
	endif

! Read global attributes

	call nfs(nf90_get_att(ncid1,nf90_global,'pass_number',pass_in))
	call nfs(nf90_get_att(ncid1,nf90_global,'cycle_number',cycle_in))
	call nfs(nf90_get_att(ncid1,nf90_global,'absolute_pass_number',absolute_pass_number))
	call nfs(nf90_get_att(ncid1,nf90_global,'absolute_rev_number',absolute_rev_number))
	call nfs(nf90_get_att(ncid1,nf90_global,'product_name',product_name))
	call nfs(nf90_get_att(ncid1,nf90_global,'xref_orbit_data',xref_orbit_data))
	orbit_type = which_orbit_type (xref_orbit_data)

! Fix an anomaly in the REF data during March 2017

	if (product_name(83:87) == 'MAR_F' .and. absolute_rev_number < 5700 .and. cycle_in > 15) &
		cycle_in = cycle_in - 2

! Read the time dimension

	call nfs(nf90_inquire_dimension(ncid1,1,dimnm,nrec))
	if (dimnm /= 'time_01') stop 'Error reading time dimension'
	if (nrec > in_max) then
		call rads_message ('Too many measurements in input file, skipped: '//filenm)
		call nfs(nf90_close(ncid1))
		cycle
	endif
	allocate (time(nrec),lat(nrec),lon(nrec))
	call nfs(nf90_inq_varid(ncid1,'time_01',varid))
	call nfs(nf90_get_var(ncid1,varid,time))

! Read latitude and longitude

	call nfs(nf90_inq_varid(ncid1,'lat_01',varid))
	call nfs(nf90_get_var(ncid1,varid,lat))
	lat = lat * 1d-6
	call nfs(nf90_inq_varid(ncid1,'lon_01',varid))
	call nfs(nf90_get_var(ncid1,varid,lon))
	lon = lon * 1d-6

! We may have pass number 771 on input ... this belongs to the next cycle

	call next_cycle (cycle_in, pass_in)

! Write out buffer it we are in a new pass

	if (cycle_in * 1000 + pass_in > cycle_number * 1000 + pass_number) then
		call write_output
		pass_number = pass_in
		cycle_number = cycle_in
	endif

! First advance to beyond the last time tag

	do i0 = 1, nrec
		if (time(i0) > last_time) exit
	enddo
	if (i0 > 1) call write_line ('... skip', 1, i0-1, nrec, time(1), time(i0-1), '<', filenm)

! If none of the records are after last_time, skip the whole input file

	if (i0 > nrec) then
		call nfs(nf90_close(ncid1))
		deallocate (time, lat, lon)
		cycle
	endif
	last_time = time(nrec)

! Split the pass where they roll over to a new pass
! Also skip duplicated measurements within a single file

	do i = max(2,i0),nrec
		if (time(i) == time(i-1)) then
			call fill_fin (i0, i-2)
			call write_line ('... skip', i-1, i-1, nrec, time(i-1), time(i-1), '<', filenm)
			i0 = i
		else if (lat(i) > lat(i-1) .neqv. modulo(pass_number,2) == 1) then
			call fill_fin (i0, i-1)
			call write_output
			i0 = i
			pass_number = pass_number + 1
			call next_cycle (cycle_number, pass_number)
		endif
	enddo
	call fill_fin (i0, nrec)

! Deallocate time and location arrays

	deallocate (time, lat, lon)
enddo

! Dump the remainder of the input files to output

call write_output
if (sat /= '') call rads_end (S)

contains

!***********************************************************************
! Fill the array of file information

subroutine fill_fin (i0, i1)
integer, intent(in) :: i0, i1
nfile = nfile + 1
if (nfile > 20) call rads_exit ('Number of granules too large (> 20)')
fin(nfile)%ncid = ncid1
fin(nfile)%nrec = nrec
fin(nfile)%filenm = filenm
fin(nfile)%type = orbit_type
fin(nfile)%rec0 = i0
fin(nfile)%rec1 = i1
fin(nfile)%time0 = time(i0)
fin(nfile)%time1 = time(i1)
fin(nfile)%lat0 = lat(i0)
fin(nfile)%lat1 = lat(i1)
fin(nfile)%lon0 = lon(i0)
fin(nfile)%lon1 = lon(i1)
call write_line ('.. input', i0, i1, nrec, time(i0), time(i1), '<', filenm)
end subroutine fill_fin

!***********************************************************************
! Determine the type of orbit used

function which_orbit_type (xref_orbit_data)
integer :: which_orbit_type
character(len=*), intent(in) :: xref_orbit_data
select case (xref_orbit_data(10:12))
case ('POE')
	which_orbit_type = 6
case ('MDO')
	which_orbit_type = 5
case ('ROE')
	which_orbit_type = 4
case ('NAV')
	which_orbit_type = 3
case ('NAT')
	which_orbit_type = 2
case ('FPO')
	which_orbit_type = 1
case ('OSF')
	which_orbit_type = 0
case default
	which_orbit_type = 127_onebyteint
end select
end function which_orbit_type

!***********************************************************************
! Start the next cycle when the pass number rolls over

subroutine next_cycle (cycle, pass)
integer(fourbyteint), intent(inout) :: cycle, pass
if (pass > 770) then
	cycle = cycle + (pass-1) / 770
	pass = modulo(pass-1,770) + 1
endif
end subroutine next_cycle

!***********************************************************************
! Write whatever has been buffered so far to an output file

subroutine write_output
integer(fourbyteint) :: nrec, ncid1, ncid2, varid1, varid2, varid3, xtype, ndims, &
	dimids(2), dimid2, natts, i, nvars, idxin(2)=1, idxut(2)=1, nout
character(len=rads_naml) :: dirnm, prdnm, outnm, attnm, varnm
real(eightbytereal), allocatable :: darr1(:)
integer(fourbyteint), allocatable :: iarr1(:)
logical :: exist
integer(onebyteint), parameter :: flag_values(0:6) = int((/0,1,2,3,4,5,6/), onebyteint)

! How many records are buffered for output?
! Skip if there is nothing left

if (nfile == 0) return
nrec = sum(fin(1:nfile)%rec1 - fin(1:nfile)%rec0 + 1)

! Open the output file. Make directory if needed.

605 format (a,'/c',i3.3)
610 format (a,i3.3,'_',i3.3,a,'.nc')

write (dirnm,605) trim(destdir),cycle_number
inquire (file=dirnm,exist=exist)
if (.not.exist) call system('mkdir -p '//dirnm)
write (prdnm,610) product_name(:15),cycle_number,pass_number,product_name(77:94)
outnm = trim(dirnm) // '/' // trim(prdnm)
inquire (file=outnm,exist=exist)

! If exist, then keep the file if the buffer is smaller or equal in size
! If it is larger, delete the existing file

if (exist) then
	call nfs(nf90_open(outnm,nf90_nowrite,ncid2))
	call nfs(nf90_inquire_dimension(ncid2,1,len=nout))
	call nfs(nf90_get_att(ncid2,nf90_global,'first_meas_time',date(1)))
	call nfs(nf90_get_att(ncid2,nf90_global,'last_meas_time',date(2)))
	call nfs(nf90_close(ncid2))
	if (nrec <= nout) then
		do i = 1, nfile
			! Release netCDF file when reaching end
			if (fin(i)%rec1 == fin(i)%nrec) call nfs(nf90_close(fin(i)%ncid))
		enddo
		write (*,620) 'Keeping ', 1, nout, nout, date(1:2), '>', trim(outnm)
		nfile = 0
		return
	endif
	call system('rm -f '//outnm)
endif
620 format (a,' : ',3i6,' : ',a,' - ',a,1x,a1,1x,a)

! Create a new file

call nfs(nf90_create(outnm,nf90_write+nf90_nofill,ncid2))
call nfs(nf90_set_fill(ncid2,nf90_nofill,i))

! Create the time dimension

call nfs(nf90_def_dim(ncid2,'time_01',nrec,dimid2))

! Copy all the variable definitions and attributes

ncid1 = fin(1)%ncid
call nfs(nf90_inquire(ncid1,nvariables=nvars,nattributes=natts))
varid2 = 0
do varid1 = 0, nvars
	if (varid1 > 0) then
		call nfs(nf90_inquire_variable(ncid1,varid1,varnm,xtype,ndims,dimids,natts))
		! Skip all listed excluded variables, all 20-Hz variables
		! Skip also all uint variables because the netCDF library doesn't work with them
		! (they occur only in enhanced_measurements.nc)
		if (excluded(varnm) .or. ndims > 1 .or. dimids(1) > 1 .or. xtype == nf90_uint) cycle
		call nfs(nf90_def_var(ncid2,varnm,xtype,dimids(1:ndims),varid2))
	endif
	do i = 1,natts
		call nfs(nf90_inq_attname(ncid1,varid1,i,attnm))
		call nfs(nf90_copy_att(ncid1,varid1,attnm,ncid2,varid2))
	enddo
enddo

! Add the orbit data type

call nfs(nf90_def_var(ncid2,'orbit_data_type',nf90_byte,dimid2,varid3))
call nfs(nf90_put_att(ncid2,varid3,'long_name','Type of data file used for orbit computation'))
call nfs(nf90_put_att(ncid2,varid3,'_FillValue',127_onebyteint))
call nfs(nf90_put_att(ncid2,varid3,'flag_values',flag_values))
call nfs(nf90_put_att(ncid2,varid3,'flag_meanings','scenario prediction navatt doris_nav gnss_roe doris_moe poe'))
call nfs(nf90_put_att(ncid2,varid3,'coordinates','lon_01 lat_01'))

! Determine absolute pass, rev, and equator crossing information

absolute_pass_number = (cycle_number-1)*nr_passes+pass_number-54
absolute_rev_number = absolute_pass_number / 2
call rads_predict_equator (S, P, cycle_number, pass_number)

! Overwrite some attributes and product name

call write_line ('Creating', 1, nrec, nrec, fin(1)%time0, fin(nfile)%time1,'>', outnm)
call strf1985f(date(3),P%equator_time)

call nfs(nf90_put_att(ncid2,nf90_global,'product_name',prdnm))
call nfs(nf90_put_att(ncid2,nf90_global,'cycle_number',cycle_number))
call nfs(nf90_put_att(ncid2,nf90_global,'pass_number',pass_number))
call nfs(nf90_put_att(ncid2,nf90_global,'absolute_pass_number',absolute_pass_number))
call nfs(nf90_put_att(ncid2,nf90_global,'absolute_rev_number',absolute_rev_number))
call nfs(nf90_put_att(ncid2,nf90_global,'equator_time',date(3)))
call nfs(nf90_put_att(ncid2,nf90_global,'equator_longitude',P%equator_lon))
call nfs(nf90_put_att(ncid2,nf90_global,'first_meas_time',date(1)))
call nfs(nf90_put_att(ncid2,nf90_global,'last_meas_time',date(2)))
call nfs(nf90_put_att(ncid2,nf90_global,'first_meas_lat',fin(1)%lat0))
call nfs(nf90_put_att(ncid2,nf90_global,'last_meas_lat',fin(nfile)%lat1))
call nfs(nf90_put_att(ncid2,nf90_global,'first_meas_lon',fin(1)%lon0))
call nfs(nf90_put_att(ncid2,nf90_global,'last_meas_lon',fin(nfile)%lon1))
call nfs(nf90_enddef(ncid2))

! Copy all data elements

nout = 0
do i = 1,nfile
	nrec = fin(i)%rec1 - fin(i)%rec0 + 1
	if (nrec == 0) stop "nrec == 0"
	allocate (darr1(nrec),iarr1(nrec))
	ncid1 = fin(i)%ncid
	idxin(2) = fin(i)%rec0
	idxut(2) = nout + 1
	varid2 = 0
	do varid1 = 1,nvars
		call nfs(nf90_inquire_variable(ncid1,varid1,varnm,xtype,ndims,dimids,natts))
		if (excluded(varnm) .or. ndims > 1 .or. dimids(1) > 1 .or. xtype == nf90_uint) cycle
		call nfs(nf90_inq_varid(ncid2,varnm,varid2))
		if (xtype == nf90_double) then
			call nfs(nf90_get_var(ncid1,varid1,darr1,idxin(2:2)))
			call nfs(nf90_put_var(ncid2,varid2,darr1,idxut(2:2)))
		else
			call nfs(nf90_get_var(ncid1,varid1,iarr1,idxin(2:2)))
			call nfs(nf90_put_var(ncid2,varid2,iarr1,idxut(2:2)))
		endif
	enddo
	iarr1 = fin(i)%type
	call nfs(nf90_put_var(ncid2,varid3,iarr1,idxut(2:2)))
	nout = nout + nrec
	deallocate (darr1,iarr1)
	! Release netCDF file when reaching end
	if (fin(i)%rec1 == fin(i)%nrec) call nfs(nf90_close(fin(i)%ncid))
enddo

! Close output

call nfs(nf90_close(ncid2))
nfile = 0

end subroutine write_output

subroutine write_line (word, rec0, rec1, nrec, time0, time1, dir, filenm)
character(len=*), intent(in) :: word, dir, filenm
integer, intent(in) :: rec0, rec1, nrec
real(eightbytereal), intent(in) :: time0, time1
call strf1985f(date(1),time0+sec2000)
call strf1985f(date(2),time1+sec2000)
write (*,620) word, rec0, rec1, nrec, date(1:2), dir, trim(filenm)
620 format (a,' : ',3i6,' : ',a,' - ',a,1x,a1,1x,a)
end subroutine write_line


function excluded (varnm)
character(len=*), intent(in) :: varnm
logical :: excluded
excluded = (index(exclude_list,','//trim(varnm)//',') > 0)
end function excluded

end program s3combine
