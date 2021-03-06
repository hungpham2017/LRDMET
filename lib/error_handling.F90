module errors
! Module for printing out warnings/errors.
! James Spencer, CUC3, University of Cambridge.
!
! Copyright (c) 2009 James Spencer.
!
! environment_report prints out a summary of the environment:
!   * when the code was compiled;
!   * the VCS BASE repository version (there's no guarantee that the code wasn't
!     changed!);
!   * whether the working directory contains local changes;
!   * the working directory;
!   * the host computer.
! 
! Permission is hereby granted, free of charge, to any person
! obtaining a copy of this software and associated documentation
! files (the "Software"), to deal in the Software without
! restriction, including without limitation the rights to use,
! copy, modify, merge, publish, distribute, sublicense, and/or sell
! copies of the Software, and to permit persons to whom the
! Software is furnished to do so, subject to the following
! conditions:
!
! The above copyright notice and this permission notice shall be
! included in all copies or substantial portions of the Software.
!
! THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
! EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
! OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
! NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
! HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
! WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
! FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
! OTHER DEALINGS IN THE SOFTWARE.

implicit none

contains

    subroutine stop_all(sub_name,error_msg)
        ! Stop calculation due to an error.
        ! Exit with code 999.
        !
        ! In:
        !    sub_name:  calling subroutine name.
        !    error_msg: error message.

        character(*), intent(in) :: sub_name,error_msg

        ! It seems that giving STOP a string is far more portable.
        ! mpi_abort requires an integer though.
        character(3), parameter :: error_str='999'

        write (6,'(/a7)') 'ERROR.'
        write (6,'(1X,a)') 'LRDMET stops in subroutine: '//adjustl(sub_name)//'.'
        write (6,'(a9,a)') 'Reason: ',adjustl(error_msg)
        write (6,'(1X,a10)') 'EXITING...'

        call flush(6)

        ! Abort all processors.
        ! error code is given to mpi_abort which (apparently) returns it to the invoking environment.

        stop error_str

        return

    end subroutine stop_all

    subroutine warning(sub_name,error_msg,blank_lines)
        ! Print a warning message in a (helpfully consistent) format.
        ! I was bored of typing the same formatting in different places. ;-)
        !
        ! In:
        !    sub_name:  calling subroutine name.
        !    error_msg: error message.
        !    blank_lines (optional): if 0, print a blank line either side of the
        !        warning message.  This is the default behaviour. If 1, a blank
        !        line is only printed before the warning message.  If 2, a blank
        !        line is only printed after the warning message.  No blank lines
        !        are printed for any other value.

        character(*), intent(in) :: sub_name,error_msg
        integer, optional :: blank_lines

        call write_blank(1)
        write (6,'(1X,a)') 'WARNING: error in '//adjustl(sub_name)//'.'
        write (6,'(1X,a)') adjustl(error_msg)
        call write_blank(2)

        return

        contains

            subroutine write_blank(point)

                integer :: point

                if (present(blank_lines)) then
                    if (blank_lines == 0) then
                        write (6,'()')
                    else if (blank_lines == point) then
                        write (6,'()')
                    end if
                else
                    write (6,'()')
                end if

            end subroutine write_blank

    end subroutine warning

    subroutine quiet_stop(msg)
        ! Exit without making any noise.  Useful for when there's no error, but you
        ! still want to exit midway through a calculation (e.g. for testing purposes,
        ! or for use with the SOFTEXIT functionality).
        ! In:
        !    msg (optional) : Print msg before exiting if msg is present.

        character(*), intent(in), optional :: msg

        if (present(msg)) then
            write (6,'(1X,a)') adjustl(msg)
            call flush(6)
        end if

        ! Abort all processors.
        ! error code is given to mpi_abort which (apparently) returns it to the invoking environment.
        stop

    end subroutine quiet_stop

end module errors
