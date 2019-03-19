#!/bin/bash

###################### SETTINGS ######################

tif_folder='/cloud/gis_data/srtm/hgt'        # folder with processed *.hgt.tif files (like N46E116.hgt.tif). Must contain ONLY files for import.
tmp_dir='/cloud/gis_data/srtm/output_tmp'    # temp directory for files, processed during import
log_file='/cloud/gis_data/srtm/contours.log' # file to redirect output

database='contours'        # database for contours
table='contours'           # table for contours
elevation_column='ele'     # column to store elevation values
geometry_column='way'      # column to store contour geometries

######################################################



################## TEST MODE #######################
test_mode=false # set true for test on small data set

if [ "$test_mode" = true ]
then
	tif_folder='/cloud/gis_data/srtm/hgt_test'

	rm -R $tif_folder
	mkdir $tif_folder

	cd $tif_folder
	wget http://viewfinderpanoramas.org/dem3/I28.zip #Madeira - only 3 tif files
	unzip -j -o I28.zip
	rm I28.zip
	for hgtfile in *.hgt; do gdal_fillnodata.py $hgtfile $hgtfile.tif && rm $hgtfile; done;
	#exit 1;
fi
####################################################


# misc variables for progress and database size monitoring
tif_count=$(find $tif_folder -name "*.tif" | wc -l)
tif_current=1
tif_percent=0
db_size=0

# 1. Recreate database
dropdb --if-exists $database
createdb $database
psql $database -c 'CREATE EXTENSION postgis;' &>> $log_file;
init_table=true


# 2. Remove log file
rm -rf $log_file

# 3. Create temp directory (if not exist)
mkdir $tmp_dir


echo "Total tif files count: $tif_count"

# 4. Iterate hgt.tif files

cd $tif_folder
for tif_file in *.tif; 
do 

	echo -ne "process $tif_file $tif_current of $tif_count ($tif_percent %, $db_size)\r";
	
	# 4.1 Warp and reproject
	gdalwarp -co BIGTIFF=YES -co TILED=YES -co COMPRESS=LZW -co PREDICTOR=2 -t_srs "+proj=merc +ellps=sphere +R=6378137 +a=6378137 +units=m" -r bilinear -tr 90 90 $tif_file $tmp_dir/$tif_file.warp-90.tif &>> $log_file;
	
	# 4.2 Create contours shp file
	gdal_contour -i 10 -a $elevation_column  ./$tif_file $tmp_dir/$tif_file.shp &>> $log_file;

	# 4.3 Create table
	if [ "$init_table" = true ]
	then
		shp2pgsql -S -p -g $geometry_column $tmp_dir/$tif_file.shp $table 2>> $log_file | psql -q -d $database &>> $log_file;
		init_table=false;
	fi

	# 4.4 Import shp to database
	shp2pgsql -S -a -g $geometry_column $tmp_dir/$tif_file.shp $table 2>> $log_file | psql -q -d $database;

	# 4.5 Remove temp files
	rm $tmp_dir/$tif_file.warp-90.tif
	rm $tmp_dir/$tif_file.shp
	rm $tmp_dir/$tif_file.shx
	rm $tmp_dir/$tif_file.dbf
	rm $tmp_dir/$tif_file.prj

	# misc progress and db size calculations
    tif_current=$((tif_current+1))
    tif_percent=$(((tif_current * 100) / tif_count))
    db_size=$(psql -d $database -t -c "SELECT pg_size_pretty(pg_database_size(pg_database.datname)) AS size FROM pg_database WHERE pg_database.datname = '$database';")

done;


# 5. Remove first and last point of all non-closed contours
# more info: https://gis.stackexchange.com/questions/256289/gdal-contour-line-generation-at-dem-edges

psql -d $database -c 'update $table set $geometry_column = ST_RemovePoint(ST_RemovePoint($geometry_column, ST_NPoints($geometry_column) - 1), 0) where ST_IsClosed($geometry_column) = false;' &>> $log_file;

# 6. Remove temp dir (optional)
#rm -R $tmp_dir

echo -e "\nImport Finished";

exit 1;

# TODO:
# 1. list all required packages (postgis, etc)
# 2. check -I option for shp2pgsql (create a GiST index on the geometry column)
# 3. check step 5 correctness on all data
# 4. may be find replacement fo step 5 (ogr2ogr clipsrc)
# 5. check ogr2org simplify to decrease total db size
# 6. check do not warp/reproject tif but reproject shp
# 7. move settings to input parameters?