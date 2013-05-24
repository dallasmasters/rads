!-----------------------------------------------------------------------
! $Id$
!
! Copyright (c) 2011-2013  Remko Scharroo (Altimetrics LLC)
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

!*rads_add_ncep -- Add NCEP meteo models to RADS data
!+
! This program adjusts the contents of RADS altimeter data files
! with values computed from NCEP meteorological models.
! The models provide sea level pressure, columnal water vapour content
! and surface temperature.
!
! Input grids are found in directories $ALTIM/data/ncep
!
! Interpolation is performed in 6-hourly grids of 2.5x2.5 degree
! spacing; bi-cubic in space, linear in time.
!
! usage: rads_add_ncep [data-selectors] [options]
!
! References:
!
! Hopfield, H. S. (1969), Two-quartic tropospheric refractivity profile for
! correcting satellite data, J. Geophys. Res., 74(18), 4487-4499,
! 10.1029/JC074i018p04487.
!
! Saastamoinen, J. (1972), Atmospheric corrections for the troposphere and
! stratosphere in radio ranging of satellites, in The Use of Artificial
! Satellites for Geodesy, Geophys. Monogr. Ser., vol. 15, edited by
! S. W. Hendriksen, A. Mancini, and B. H. Chovitz, pp. 247-251,
! American Geophysical Union, Washington, D.C.
!
! Bevis, M., S. Businger, S. Chriswell, T. A. Herring, R. A. Anthes, C. Rocken,
! and R. H. Ware (1994), GPS meteorology: Mapping zenith wet delays onto
! precipitable water, J. Applied Meteorology, 33(3), 379-386,
! 10.1175/1520-0450(1994)033<0379:GMMZWD>2.0.CO;2.
!
! Mendes, V. B., G. Prates, L. Santos, and R. B. Langley (2000), An evaluation
! of the accuracy of models for the determination of the weighted mean temperature
! of the atmosphere, in Proc. of the 2000 National Technical Meeting of The
! Institute of Navigation, Anaheim, CA, January 2000, pp. 433-438.
!
! Petit, G., and B. Luzum (Eds.) (2010), IERS Conventions (2010),
! IERS Technical Note 36, Verlag des Bundesamts für Kartographie und Geodäsie.
!-----------------------------------------------------------------------
program rads_add_ncep

use rads
use rads_misc
use rads_grid
use rads_devel
use rads_netcdf
use tides
use meteo_subs
use netcdf

! Command line arguments

type(rads_sat) :: S
type(rads_pass) :: P
integer(fourbyteint) :: j, cyc, pass

! Data elements

character(rads_naml) :: path
integer(fourbyteint) :: hex,hexold=-99999
type(airtideinfo) :: airinfo
real(eightbytereal), parameter :: rad2=2d0*atan(1d0)/45d0
logical :: dry_on=.false., wet_on=.false., ib_on=.false., air_on=.false., new=.false., &
	air_plus=.false., error

! Model data

character(len=80), parameter :: dry_fmt = 'slp.%Y.nc', wet_fmt = 'pr_wtr.eatm.%Y.nc', tmp_fmt = 'air.sig995.%Y.nc'
type :: model_
	type(grid) :: dry, wet, tmp
end type
type(model_) :: m1, m2

! Model parameters, see Bevis et al [1994]

real(eightbytereal), parameter :: Rw = 461.5d3	! Gas constant water vapour per volume (Pa/K)
real(eightbytereal), parameter :: k2p = 0.221d0, k3 = 3739d0	! Refractivity constants (K/Pa, K^2/Pa)

! Initialise

call synopsis ('--head')
call rads_set_options ('dwain dry wet air ib all new')
call rads_init (S)

! Get $ALTIM/data/ncep/ directory

call parseenv ('${ALTIM}/data/ncep/', path)

! Which corrections are to be provided?

do j = 1,rads_nopt
	select case (rads_opt(j)%opt)
	case ('d', 'dry')
		dry_on = .true.
	case ('w', 'wet')
		wet_on = .true.
	case ('a', 'air')
		air_on = .true.
	case ('i', 'ib')
		ib_on = .true.
	case ('n', 'new')
		new = .true.
	case ('all')
		dry_on = .true.
		wet_on = .true.
		air_on = .true.
		ib_on = .true.
	end select
enddo

! Init air tide

if (dry_on .or. ib_on) call airtideinit ('airtide', airinfo)

! Correct existing ECMWF dry tropo correction for air tide on data of Envisat,
! TOPEX, Poseidon, and ERS-1/2 (but not REAPER data)

air_plus = (air_on .and. (S%sat == 'e1' .or. S%sat == 'e2' .or. S%sat == 'n1' .or. &
	S%sat == 'tx' .or. S%sat == 'pn') .and. index(P%original,'REAPER') < 0)

! Process all data files

do cyc = S%cycles(1), S%cycles(2), S%cycles(3)
	do pass = S%passes(1), S%passes(2), S%passes(3)
		call rads_open_pass (S, P, cyc, pass, .true.)
		if (P%ndata > 0) call process_pass (P%ndata)
		call rads_close_pass (S, P)
	enddo
enddo

contains

!-----------------------------------------------------------------------
! Print synopsis
!-----------------------------------------------------------------------

subroutine synopsis (flag)
character(len=*), optional :: flag
if (rads_version ('$Revision$', 'Add NCEP meteo models to RADS data', flag=flag)) return
call synopsis_devel (' [processing_options]')
write (*,1310)
1310  format (/ &
'Additional [processing_options] are:'/ &
'  -d, --dry                 Add NCEP dry tropospheric correction' / &
'  -w, --wet                 Add NCEP wet tropospheric correction' / &
'  -a, --air                 Add air tide' / &
'  -i, --ib                  Add static inverse barometer correction' / &
'  --all                     All of the above' / &
'  -n, --new                 Only add variables when not yet existing')
stop
end subroutine synopsis

!-----------------------------------------------------------------------
! Process a single pass
!-----------------------------------------------------------------------

subroutine process_pass (n)
integer(fourbyteint), intent(in) :: n
integer(fourbyteint) :: i
real(eightbytereal) :: time(n), lat(n), lon(n), h(n), surface_type(n), dry(n), wet(n), ib(n), air(n), &
	f1, f2, g1, g2, slp, dslp, slp0, iwv, tmp

! Formats

551  format (a,' ...',$)
552  format (i5,' records changed')

write (*,551) trim(P%filename)

! If "new" option is used, write only when fields are not yet available

if (new .and. nft(nf90_inq_varid(P%ncid,'dry_tropo_ncep',i)) .and. &
	nft(nf90_inq_varid(P%ncid,'wet_tropo_ncep',i))) then
	write (*,552) 0
	return
endif

! Get time and position

call rads_get_var (S, P, 'time', time, .true.)
call rads_get_var (S, P, 'lat', lat, .true.)
call rads_get_var (S, P, 'lon', lon, .true.)
call rads_get_var (S, P, 'topo', h, .true.)
call rads_get_var (S, P, 'surface_type', surface_type, .true.)

! Correct DNSC08 or DTU10 topography of the Caspian Sea (-R46.5/54.1/36.5/47.1)
! It has bathymetry in both models in stead of lake topography (about -27 m)

do i = 1,n
	if (lon(i) > 46.5d0 .and. lon(i) < 54.1d0 .and. &
		lat(i) > 36.5d0 .and. lat(i) < 47.1d0 .and. &
		surface_type(i) > 2.5d0) h(i) = -27d0
enddo

! Get global pressure

call globpres(4,P%equator_time,slp0)

! Process data records

do i = 1,n
	f2 = time(i)/21600d0
	hex = floor(f2)	! Counter of 6-hourly periods

! Load new grids when entering new 6-hour period

	if (hex /= hexold) then
		if (hex == hexold + 1) then
			m1 = m2
			error = get_grids (hex+1,m2)
		else
			error = get_grids (hex,m1)
			if (.not.error) error = get_grids (hex+1,m2)
		endif
		if (error) then
			write (*,'(a)') 'Model switched off.'
			dry_on = .false.
			ib_on = .false.
			wet_on = .false.
			exit
		endif
		hexold = hex
	endif

! Linearly interpolation in time, bi-cubic spline interpolation in space

	if (lon(i) < 0d0) lon(i) = lon(i) + 360d0
	f2 = f2 - hex
	f1 = 1d0 - f2

! Interpolate surface temperature in space and time

	tmp = f1 * grid_lininter(m1%tmp,lon(i),lat(i)) + f2 * grid_lininter(m2%tmp,lon(i),lat(i))

! Correct sea level pressure grids for altitude over land and lakes using Hopfield [1969]
! Convert pressure (mbar) to simple IB (m) if requested and over ocean
! Convert sea level pressure (mbar) to dry correction (m) using Saastamoinen models as referenced
! in IERS Conventions Chap 9
! Convert precipitable water (kg/m^2) to wet correction (m) using Mendes et al. [2000] and
! Bevis et al. [1994]

	if (surface_type(i) > 1.5d0) then ! Land and lakes
		g1 = -22768d-7 / (1d0 - 266d-5*cos(lat(i)*rad2) - 28d-8*h(i)) * pp_hop(h(i),lat(i),tmp)
		g2 = 0d0	! Set IB to zero
	else    ! Ocean (altitude is zero)
		g1 = -22768d-7 / (1d0 - 266d-5*cos(lat(i)*rad2))
		g2 = -9.948d-3
	endif

! Interpolate sea level pressure in space and time and add airtide correction

	if (dry_on .or. ib_on .or. air_on) then
		slp = f1 * grid_lininter(m1%dry,lon(i),lat(i)) + f2 * grid_lininter(m2%dry,lon(i),lat(i))

		! Remove-and-restore the air tide
		dslp = airtide (airinfo, time(i), lat(i), lon(i)) &
			- f1 * airtide (airinfo, hex * 21600d0, lat(i), lon(i)) &
			- f2 * airtide (airinfo, (hex+1) * 21600d0, lat(i), lon(i))
		slp = slp * 1d-2 + dslp ! Convert Pa to hPa (mbar)

		! Convert sea level pressure to dry tropo correction after Saastamoinen [1972]
		dry(i) = slp * g1
		air(i) = dslp * g1

		! Convert sea level pressure to static inverse barometer
		ib(i) = (slp - slp0) * g2
	endif

! Interpolate integrated water vapour in space and time

	if (wet_on) then
		iwv = f1 * grid_lininter(m1%wet,lon(i),lat(i)) + f2 * grid_lininter(m2%wet,lon(i),lat(i))
		! Convert surface temperature to mean temperature after Mendes et al. [2000]
		tmp = 50.4d0 + 0.789d0 * tmp
		! Convert integrated water vapour and mean temp to wet tropo correction
		! Also take into account conversion of iwv from kg/m^3 (= mm) to m.
		wet(i) = -1d-9 * Rw * (k3 / tmp + k2p) * iwv
	endif

enddo

! If no more fields are determined, abort.

if (.not.(dry_on .or. ib_on .or. wet_on)) then
	write (*,552) 0
	stop
endif

! Store all data fields

call rads_put_history (S, P)

if (dry_on) call rads_def_var (S, P, 'dry_tropo_ncep')
if (wet_on) call rads_def_var (S, P, 'wet_tropo_ncep')
if (ib_on ) call rads_def_var (S, P, 'inv_bar_static')
if (air_on) call rads_def_var (S, P, 'dry_tropo_airtide')

if (dry_on) call rads_put_var (S, P, 'dry_tropo_ncep', dry)
if (wet_on) call rads_put_var (S, P, 'wet_tropo_ncep', wet)
if (ib_on ) call rads_put_var (S, P, 'inv_bar_static', ib)
if (air_on) call rads_put_var (S, P, 'dry_tropo_airtide', air)
if (air_plus) then
	call rads_get_var (S, P, 'dry_tropo_ecmwf', dry)
	call rads_put_var (S, P, 'dry_tropo_ecmwf', dry+air)
endif

write (*,552) n
end subroutine process_pass

!-----------------------------------------------------------------------
! get_grids -- Load necessary NCEP meteo grids
!-----------------------------------------------------------------------

function get_grids (hex, model)
integer (fourbyteint), intent(in) :: hex
type(model_), intent(inout) :: model
logical :: get_grids
!
! Input are yearly files with required fields of the form:
! $(ALTIM)/data/ncep/slp.2012.nc
!
! <hex> specifies the number of 6-hourly blocks since 1 Jan 1985.
! Data is stored in a buffer <model>
!-----------------------------------------------------------------------
get_grids = .true.
if (get_grid(trim(path)//wet_fmt,hex,model%wet) /= 0) return
if (get_grid(trim(path)//tmp_fmt,hex,model%tmp) /= 0) return
if (get_grid(trim(path)//dry_fmt,hex,model%dry) /= 0) return
get_grids = .false.
end function get_grids

!-----------------------------------------------------------------------
! get_grid -- Special grid loading routine for NetCDF meteo grids
!-----------------------------------------------------------------------

function get_grid (filenm, hex, info)
character(len=*), intent(in) :: filenm
integer(fourbyteint), intent(in) :: hex
type(grid), intent(out) :: info
integer(fourbyteint) :: get_grid
!
! Input are sea level pressure files (slp.%Y.nc) and/or precipitable
! water vapour files (pr_wtr.eatm.%Y.nc), where %Y is the
! year number. <hex> specifies the number of 6-hourly blocks since 1 Jan 1985.
!
! Data is stored in a buffer pointed to by the returned value.
!
! Units are mbar and kg/m^2, stored as integers with units 0.01 mbar and 0.01
! kg/m^2. However, the last digit is not significant (always 0).
!-----------------------------------------------------------------------
character(80) :: fn
integer(fourbyteint) :: ncid,x_id,y_id,t_id,v_id,i,h1985,tmin,tmax,start(3)=1,l,strf1985
real(eightbytereal) :: time(2),nan
integer(fourbyteint) :: nx,ny,nt,hour
integer(twobyteint), allocatable :: tmp(:,:)

! Determine file name

hour = hex * 6
l = strf1985(fn,filenm,hour*3600)
nan = 0d0
nan = nan/nan

! Free grid

call grid_free(info)

! Open input file

1300 format (a,': ',a)
if (nft(nf90_open(fn,nf90_nowrite,ncid))) then
	write (*,1300) 'Error opening file',fn(:l)
	get_grid = 1
	i = nf90_close(ncid)
	return
endif

! Check if netcdf file contains SLP or PR_WTR or AIR.

if (.not.nft(nf90_inq_varid(ncid,'slp',v_id))) then
else if (.not.nft(nf90_inq_varid(ncid,'pr_wtr',v_id))) then
else if (.not.nft(nf90_inq_varid(ncid,'air',v_id))) then
else
	write (*,1300) 'Error with ID# for data grid: no slp, pr_wtr, or air in',fn(:l)
	get_grid = 2
	i = nf90_close(ncid)
	return
endif

! Get the x, y and t dimensions

i = 0
if (nft(nf90_inq_dimid(ncid,'lon',x_id))) i = i + nf90_inq_dimid(ncid,'longitude',x_id)
if (nft(nf90_inq_dimid(ncid,'lat',y_id))) i = i + nf90_inq_dimid(ncid,'latitude',y_id)
i = i + nf90_inq_dimid(ncid,'time',t_id)


if (i + nf90_inquire_dimension(ncid,x_id,len=nx) + nf90_inquire_dimension(ncid,y_id,len=ny) + &
	nf90_inquire_dimension(ncid,t_id,len=nt) /= 0) then
	write (*,1300) 'Error getting data dimensions in',fn(:l)
	get_grid = 2
	i = nf90_close(ncid)
	return
endif

! Get start/stop times in hours since epoch

start(3) = nt
if (nf90_inq_varid(ncid,'time',t_id) + nf90_get_var(ncid,t_id,time(1:1)) + &
	nf90_get_var(ncid,t_id,time(2:2),start(3:3)) /= 0) then
	write (*,1300) 'Error getting time range in',fn(:l)
	get_grid = 2
	i = nf90_close(ncid)
	return
endif

! Convert time range to hours since 1985

h1985 = 17391432
tmin = nint(time(1)) - h1985
tmax = nint(time(2)) - h1985

if (hour < tmin .or. hour > tmax) then
	write (*,1300) 'Hour out of bounds in',fn(:l)
	get_grid = 5
	i = nf90_close(ncid)
	return
endif

! Get scale factor, offset and missing value

if (nft(nf90_get_att(ncid,v_id,'add_offset',info%z0))) info%z0 = 0
if (nft(nf90_get_att(ncid,v_id,'scale_factor',info%dz))) info%dz = 1
if (nft(nf90_get_att(ncid,v_id,'missing_value',info%znan))) info%znan = nan

! Determine other header values and allocate buffer

if (info%ntype == 0) then
	info%ntype = nf90_int2
	info%nx = nx
	info%dx = 360d0 / nx
	info%xmin = 0d0
	info%xmax = (nx-1) * info%dx
	info%ny = ny
	info%dy = 180d0 / (ny-1)
	info%ymin = -90d0
	info%ymax = 90d0
	info%nxwrap = nx
	allocate (info%grid_int2(nx,ny))
endif

! Read only the required grid

allocate (tmp(nx,ny))
start(3)=(hour-tmin)/6+1
if (nft(nf90_get_var(ncid,v_id,tmp,start))) call fin('Error reading data grid')

! Reverse the order of the latitudes

info%grid_int2(:,1:ny) = tmp(:,ny:1:-1)
deallocate (tmp)

i = nf90_close(ncid)
get_grid = 0

end function get_grid

end program rads_add_ncep